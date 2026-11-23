# frozen_string_literal: true

# Single-user sandbox example. Set DIDIT_API_KEY (bank-data permission) and
# DIDIT_WEBHOOK_SECRET. Forward HTTPS POSTs for /webhooks/didit to this receiver.
#   gem install didit-sdk rackup puma
#   DIDIT_LINK_FILE="$(mktemp -d)/bank-link" rackup examples/bank_connection.ru
# Open the URL in the private file as the person connecting the bank. Remove
# the file after use. Stop the receiver after it reports the account count.

require "didit"

client = Didit::Client.new
secret = ENV.fetch("DIDIT_WEBHOOK_SECRET")
path = ENV.fetch("DIDIT_LINK_FILE")
link = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
  created = client.bank.create_link(access: "ongoing", data: ["accounts"])
  file.puts(created.url)
  created
end
warn "Your private Bank Link is in #{path}"

map "/webhooks/didit" do
  receiver = lambda do |env|
    return [405, { "allow" => "POST" }, []] unless env["REQUEST_METHOD"] == "POST"

    body = env.fetch("rack.input").read(65_537)
    return [413, {}, []] if body && body.bytesize > 65_536

    event = client.webhooks.verify(body.to_s, env, secret)
    return [204, {}, []] unless event.is_a?(Didit::Webhooks::BankConnectionCreatedEvent)
    return [400, {}, []] unless event.connection_id.is_a?(String) && !event.connection_id.empty?

    connection_id = client.bank.get_link(link.id).connection_id
    return [503, {}, []] unless connection_id # Retry if link completion is still being recorded.
    return [204, {}, []] unless connection_id == event.connection_id

    count = 0
    cursor = nil
    loop do
      page = client.bank.list_accounts(connection_id, cursor: cursor, limit: 50)
      count += page.items.size
      cursor = page.next_cursor
      break unless cursor
    end
    puts "Connected accounts: #{count}"
    [204, {}, []]
  rescue Didit::WebhookVerificationError
    [401, {}, []]
  rescue Didit::DiditError
    [503, {}, []]
  end
  run receiver
end
