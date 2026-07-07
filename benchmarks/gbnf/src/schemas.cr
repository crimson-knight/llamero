require "llamero"

# Benchmark schema shapes, graded per GBNF_SPEC.md D11:
# flat (~5 fields), medium nested, complex NEAR the cliff budget,
# and one deliberately PAST the budget for cliff characterization.

# --- Task 1: flat, 5 required scalar fields --------------------------------
class FlatInvoice < Llamero::BaseGrammar
  property invoice_number : String = ""
  property customer_name : String = ""
  property total_amount : Float64 = 0.0
  property currency : String = ""
  property paid : Bool = false

  def initialize
  end
end

# --- Task 2: medium, one nested object + an array --------------------------
class ContactAddress < Llamero::BaseGrammar
  property street : String = ""
  property city : String = ""
  property country : String = ""

  def initialize
  end
end

class ContactCard < Llamero::BaseGrammar
  property name : String = ""
  property age : Int32 = 0
  property email : String = ""
  property address : ContactAddress = ContactAddress.new
  property tags : Array(String) = [] of String

  def initialize
  end
end

# --- Task 3: complex, deliberately NEAR the cliff budget --------------------
# Depth 5 object chain (budget max 8) and exactly 6 optional fields on the
# root object - the optional-subset cap (2^6 = 64 alternatives, the documented
# boundary of the v1 budget).
class CliffGeo < Llamero::BaseGrammar
  property lat : Float64 = 0.0
  property lon : Float64 = 0.0

  def initialize
  end
end

class CliffOffice < Llamero::BaseGrammar
  property city : String = ""
  property country : String = ""
  property geo : CliffGeo = CliffGeo.new

  def initialize
  end
end

class CliffOrg < Llamero::BaseGrammar
  property name : String = ""
  property office : CliffOffice = CliffOffice.new

  def initialize
  end
end

class CliffReporter < Llamero::BaseGrammar
  property name : String = ""
  property email : String = ""
  property org : CliffOrg = CliffOrg.new

  def initialize
  end
end

class CliffTicket < Llamero::BaseGrammar
  property id : String = ""
  property severity : Int32 = 0
  property title : String = ""
  property reporter : CliffReporter = CliffReporter.new
  property tags : Array(String) = [] of String
  property assignee : String? = nil
  property resolution : String? = nil
  property escalated : Bool? = nil
  property sla_hours : Int32? = nil
  property component : String? = nil
  property duplicate_of : String? = nil

  def initialize
  end
end

# --- Past the budget: 7 optionals (cap is 6) --------------------------------
# Used only for cliff characterization: `to_gbnf?` must return nil with a
# reason, and `:auto` must engage the schema-prompt fallback.
class CliffBreaker < Llamero::BaseGrammar
  property id : String = ""
  property severity : Int32 = 0
  property title : String = ""
  property reporter : CliffReporter = CliffReporter.new
  property tags : Array(String) = [] of String
  property assignee : String? = nil
  property resolution : String? = nil
  property escalated : Bool? = nil
  property sla_hours : Int32? = nil
  property component : String? = nil
  property duplicate_of : String? = nil
  property root_cause : String? = nil # 7th optional -> over budget

  def initialize
  end
end
