require "../spec_helper"

# LIVE proof of grammar-constrained emission against the PINNED llama.cpp
# build. Self-skips (repo law: specs must pass with no binary and no network)
# unless BOTH are present:
#
#   - the pinned build at ~/.llamero/llamacpp/<pin>/bin/llama-completion
#     (sh scripts/install_llamacpp.sh)
#   - LLAMERO_SPEC_GGUF=/path/to/a/small.gguf
#
# The schema deliberately invites rambling ("describe in detail") - an
# unconstrained small model answers with prose, so a first byte of '{' plus a
# zero-retry parse is real evidence the grammar constrained decoding.

class LiveConstrainedPerson < Llamero::BaseGrammar
  property name : String = ""
  property age : Int32 = 0
  property city : String = ""

  def initialize
  end
end

live_gguf = ENV["LLAMERO_SPEC_GGUF"]?

if live_gguf && File.exists?(live_gguf) && Llamero::LlamaCpp::Probe.new.ok?
  describe "LIVE grammar-constrained emission (pinned llama.cpp)" do
    it "emits parse-ready JSON from the first byte with zero retries" do
      backend = Llamero::LlamaCpp::CompletionBackend.new(model_path: live_gguf)

      response = backend.chat_structured(
        [Llamero::Message.user("Tell me about a person named Alice who lives in Paris. Describe them in detail.")],
        LiveConstrainedPerson,
        generation_mode: :grammar,
        max_tokens: 400
      )

      response.content[0].should eq('{')
      response.attempts.should eq(1)
      response.constraint_backend.should eq("grammar")
      parsed = response.parsed.not_nil!
      parsed.name.empty?.should be_false
    end

    it "proves the same prompt WITHOUT the grammar does not start with '{' (rambling control)" do
      backend = Llamero::LlamaCpp::CompletionBackend.new(model_path: live_gguf)
      response = backend.chat([Llamero::Message.user("Tell me about a person named Alice who lives in Paris. Describe them in detail.")], max_tokens: 60)
      response.content.starts_with?("{").should be_false
    end
  end
else
  puts "[live_constrained_spec] skipped: install the pinned llama.cpp (sh scripts/install_llamacpp.sh) and set LLAMERO_SPEC_GGUF to run the live constrained-emission proof"
end
