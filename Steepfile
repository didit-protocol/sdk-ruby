# frozen_string_literal: true

D = Steep::Diagnostic

# The hand-written core: strict.
target :core do
  signature "sig"
  check "lib"
  ignore "lib/didit/resources", "lib/didit/resources.rb", "lib/didit/types", "lib/didit/types.rb"
  library "json", "uri", "net-http", "openssl", "time", "date", "securerandom", "digest", "socket", "pathname", "stringio", "tempfile"
  configure_code_diagnostics(D::Ruby.strict)
end
