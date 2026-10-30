# frozen_string_literal: true

# The Ruby snippets in README.md and examples/ must at least be valid Ruby.
RSpec.describe "Documentation snippets" do
  let(:root) { File.expand_path("..", __dir__) }

  it "has README code blocks that parse" do
    readme = File.read(File.join(root, "README.md"), encoding: "UTF-8")
    blocks = readme.scan(/```ruby\n(.*?)```/m).flatten
    expect(blocks.size).to be > 10
    blocks.each_with_index do |code, index|
      expect { RubyVM::InstructionSequence.compile(code, "README.md block #{index + 1}") }.not_to raise_error
    end
  end

  it "has examples that parse" do
    files = Dir[File.join(root, "examples", "**", "*.{rb,ru}")]
    expect(files).not_to be_empty
    files.each do |file|
      expect { RubyVM::InstructionSequence.compile(File.read(file, encoding: "UTF-8"), file) }.not_to raise_error
    end
  end
end
