# Represents a single row in a grammar file.
#
# Not intended to be used directly.
class Llamero::Grammar::Builder::Row
  property row_name : String
  property row_content : String

  def initialize(@row_name, @row_content)
  end

  # Simple row to string representation for a gbnf grammar
  def to_s
    row_name + " ::= " + row_content
  end
end
