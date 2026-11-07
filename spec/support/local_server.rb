# frozen_string_literal: true

require "socket"

# A tiny HTTP/1.1 server on 127.0.0.1 (or ::1) for transport tests: keep-alive, dropped
# connections, slow answers. The handler gets the request and returns what to do.
class LocalServer
  Request = Struct.new(:verb, :target, :headers, :body, keyword_init: true)

  attr_reader :requests, :connections

  # handler: ->(request, index) { { status:, headers:, body:, delay:, drop:, chunks: } }
  def initialize(host: "127.0.0.1", &handler)
    @handler = handler
    @host = host
    @server = TCPServer.new(host, 0)
    @requests = Queue.new
    @connections = 0
    @lock = Mutex.new
    @threads = []
    @index = 0
    @thread = Thread.new { accept_loop }
  end

  def port
    @server.addr[1]
  end

  def url
    "http://#{@host.include?(":") ? "[#{@host}]" : @host}:#{port}"
  end

  def received
    list = []
    list << @requests.pop until @requests.empty?
    list
  end

  def stop
    @server.close
    @thread.kill
    @threads.each(&:kill)
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      @lock.synchronize { @connections += 1 }
      @threads << Thread.new(socket) { |s| serve(s) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(socket)
    while (request = read_request(socket))
      @requests << request
      index = @lock.synchronize { @index += 1 }
      action = @handler.call(request, index)
      break if action[:drop]

      sleep(action[:delay]) if action[:delay]
      write_response(socket, action)
      break if action.dig(:headers, "Connection") == "close"
    end
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close unless socket.closed?
  end

  def read_request(socket)
    line = socket.gets
    return nil if line.nil? || line.strip.empty?

    method, target = line.split
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      name, value = header.split(":", 2)
      headers[name.downcase] = value.strip
    end
    body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : nil
    Request.new(verb: method, target: target, headers: headers, body: body)
  end

  def write_response(socket, action)
    status = action.fetch(:status, 200)
    headers = { "Content-Type" => "application/json" }.merge(action.fetch(:headers, {}))
    if action[:chunks]
      headers["Transfer-Encoding"] = "chunked"
      socket.write(head(status, headers))
      action[:chunks].each { |chunk| socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n") }
      socket.write("0\r\n\r\n")
    else
      body = action.fetch(:body, "{}").to_s
      headers["Content-Length"] = body.bytesize.to_s
      socket.write(head(status, headers) + body)
    end
  end

  def head(status, headers)
    "HTTP/1.1 #{status} X\r\n#{headers.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n"
  end
end
