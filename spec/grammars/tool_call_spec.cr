require "../spec_helper"

describe Llamero::ToolCall do
  it "parses a write_file tool call" do
    tc = Llamero::ToolCall.from_json(%({"tool":"write_file","path":"src/x.cr","content":"class X\\nend"}))
    tc.tool.should eq("write_file")
    tc.path.should eq("src/x.cr")
    tc.content.should contain("class X")
    tc.known?.should be_true
  end

  it "flags unknown tools" do
    Llamero::ToolCall.from_json(%({"tool":"frobnicate"})).known?.should be_false
  end

  it "defaults unset fields (BaseGrammar)" do
    tc = Llamero::ToolCall.from_json(%({"tool":"look_up","query":"Array#tally"}))
    tc.query.should eq("Array#tally")
    tc.path.should eq("")
    tc.content.should eq("")
  end

  it "exposes a JSON schema" do
    Llamero::ToolCall.to_json_schema_string.should contain("tool")
  end
end

describe Llamero::AgenticPlan do
  it "parses an inline plan + ordered tool calls" do
    j = %({"plan":"process manager Billing::LockAccount","tool_calls":[) +
        %({"tool":"write_file","path":"src/billing/lock_account.cr","content":"class Billing::LockAccount\\nend"},) +
        %({"tool":"run","command":"crystal build src/billing/lock_account.cr --no-codegen"}]})
    plan = Llamero::AgenticPlan.from_json(j)
    plan.plan.should contain("LockAccount")
    plan.tool_calls.size.should eq(2)
    plan.tool_calls[0].path.should eq("src/billing/lock_account.cr")
    plan.tool_calls[0].content.should contain("\n")
    plan.tool_calls[1].command.should contain("crystal build")
  end

  it "nests the ToolCall schema" do
    schema = Llamero::AgenticPlan.to_json_schema_string
    schema.should contain("tool_calls")
    schema.should contain("plan")
  end

  it "serializes COMPACT (single line) even when file content has newlines" do
    plan = Llamero::AgenticPlan.from_json(
      %({"plan":"p","tool_calls":[{"tool":"write_file","path":"src/x.cr","content":"class X\\n  def y : Nil\\n  end\\nend"}]}))
    compact = plan.to_json
    compact.lines.size.should eq(1)             # one physical line — no pretty-printing
    compact.should contain("\\n")               # the content newline stays escaped
    # round-trips back to the same multi-line content
    Llamero::AgenticPlan.from_json(compact).tool_calls[0].content.should contain("\n")
  end
end
