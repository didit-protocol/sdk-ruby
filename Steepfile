# frozen_string_literal: true

D = Steep::Diagnostic

LIBRARIES = %w[json uri net-http openssl time date securerandom digest socket pathname stringio tempfile zlib].freeze
GENERATED = %w[lib/didit/resources lib/didit/resources.rb lib/didit/types lib/didit/types.rb].freeze

# The hand-written core, webhooks and Authentication: strict.
target :core do
  signature "sig"
  check "lib"
  ignore(*GENERATED)
  LIBRARIES.each { |name| library name }
  configure_code_diagnostics(D::Ruby.strict)
end

# The generated layer: its methods take Didit::OMIT as the default of optional keywords,
# which the strict profile reports, so it is checked with Steep's default profile.
target :generated do
  signature "sig"
  check(*GENERATED)
  LIBRARIES.each { |name| library name }
  configure_code_diagnostics(D::Ruby.default)
end
