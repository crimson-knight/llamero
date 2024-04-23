# The primary builder for creating a grammar file or CLI output.
# 
# This is not meant to be used directly, but rather through the `Grammar` class.
class Llamero::Grammar::Builder::GrammarBuilder(T)

  property grammar_class : T

  # A non-unique list of all non-primitive field types that are also objects from BaseGrammar
  property list_of_non_primitive_instance_vars_and_types : Array(Hash(String, String)) = [] of Hash(String, String)
  
  # A non-unqiue list of all primitive field types that need to be in the grammar output
  property list_of_primitive_instance_vars_and_types : Array(Hash(String, String)) = [] of Hash(String, String)

  # Tracks a unique list of objects to create as this grammar is created. This does not include primitives.
  property list_of_object_types_to_create_rows_for : Array(String) = [] of String

  # Tracks the JSON primitives that are being used in this grammar.
  property list_of_primitive_types_to_create_rows_for : Array(String) = [] of String

  # Collection of the IO from generating the grammar output for each child object type
  property child_grammar_output : IO::Memory = IO::Memory.new

  # The final grammar output
  property grammar_output : IO::Memory = IO::Memory.new

  # The completed grammar rows
  property rows : Array(Row) = [] of Row

  # Initialize with the grammar class that you want to use
  def initialize(@grammar_class : T)
    {% T.raise "#{T} must inherit from `BaseGrammer`" unless T <= BaseGrammar %}
  end

  # Creates the output for this grammar.
  def create_grammar_output(is_root_object : Bool = false) : IO
    if @grammar_output.empty?
      # Step 1
      create_list_of_non_primitive_objects_and_primitives
    
      # Step 2
      create_grammar_rows
      
      # Step 3
      deduplicate_any_rows_and_produce_final_output(is_root_object)
    end

    @grammar_output 
  end

  # Creates the grammar output at compile-time based on the expected child class
  private def create_list_of_non_primitive_objects_and_primitives
    @list_of_primitive_instance_vars_and_types = {% begin %}
      {%
        types = T.instance_vars.select do |ivar_meta|
          {String, Number::Primitive, Float::Primitive, Bool}.any? { |t| t >= ivar_meta.type.resolve }
        end.map do |ivar_meta|
          { "property_name" => ivar_meta.name.stringify, "property_type" => ivar_meta.type.stringify }
        end
      %}

      {{ types.empty? ? "Array(Hash(String, String)).new".id : types }}
    {% end %}

    @list_of_non_primitive_instance_vars_and_types = Array(Hash(String, String)).new
    
    {% begin %}
      {%
        types = T.instance_vars.select do |ivar_meta|
          {BaseGrammar}.any? { |r| ivar_meta.type.resolve < r }
        end
      %}

      {% for object_type in types %}
        @list_of_non_primitive_instance_vars_and_types << { 
          "property_name" => {{ object_type.name.stringify }},
          "property_type" => {{ object_type.type.type_vars.any? { |t_var| t_var == Nil } ?  object_type.type.stringify + "?" : object_type.type.stringify }}
        }
      
        @child_grammar_output << "\n" << {{ object_type.type.resolve }}.get_grammar_output_for_object
      {% end %}
    {% end %}

    {% begin %}
      {% arrays_in_the_grammar_instance_class = T.instance_vars.select { |ivar_meta| ivar_meta.type.resolve <= Array } %}
      
      {% for array_ivar in arrays_in_the_grammar_instance_class %}
        {% if {String, Number::Primitive, Float::Primitive, Bool, Time, Nil}.any? { |t| array_ivar.type.type_vars.any? { |t_var| t_var <= t.resolve } } %}
          @list_of_primitive_instance_vars_and_types << { 
            
            "property_name" => {{ array_ivar.type.type_vars.any? { |t_var| t_var == Nil } ? array_ivar.name.stringify : array_ivar.name.stringify + "?" }},
            "property_type" => {{ array_ivar.type.stringify }}
          }
        {% else %}
          {% if array_ivar.type.type_vars.any? { |t_var| t_var <= BaseGrammar } %}
            @list_of_non_primitive_instance_vars_and_types << {
              "property_name" => {{ array_ivar.name.stringify }},
              "property_type" => {{ array_ivar.type.stringify }}
            }

            {% for object_type in array_ivar.type.type_vars %}
              @child_grammar_output << {{ object_type.resolve }}.get_grammar_output_for_object
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    {% end %}

    @list_of_primitive_types_to_create_rows_for = @list_of_primitive_instance_vars_and_types.map { |ivar| ivar["property_type"] }.uniq!
  end

  private def create_grammar_rows
    @list_of_primitive_types_to_create_rows_for.each do |primitive_name|
      case primitive_name
      when /^(String|Int|Float|Bool|Time)/
        row_content = match_row_type_to_primitive(primitive_name)
      when /^Array/
        this_arrays_primitive_type = primitive_name.split("(").last[/^(String|Int|Float|Bool|Time)/]
        this_arrays_primitive_content = match_row_type_to_primitive(this_arrays_primitive_type)
        row_content = %("[]" | "["   #{this_arrays_primitive_type}   (","   #{this_arrays_primitive_type}  )*?  "]")
        primitive_name = this_arrays_primitive_type + "Array" # We are now in the format of TypeArray - IntArray, StringArray, etc.
      else
        row_content = ""
      end

      if primitive_name.ends_with?("?")
        row_content += " | null"
        primitive_name = primitive_name.split("?").first
      end

      unless row_content.blank?
        @rows << Row.new(row_name: primitive_name, row_content: row_content)
      end
    end

    # Get the child grammar IO here, split it into a list of rows, and split that into a list of rows for each object type
    @child_grammar_output.rewind.gets_to_end.split("\n", remove_empty: true).each do |row|
      split_row = row.split(" ::= ")
      @rows << Row.new(row_name: split_row.first.strip, row_content: split_row.last.strip)
    end

  end

  # A helper method for matching primitive grammar rows
  private def match_row_type_to_primitive(row_type : String) : String
    case row_type
    when "String"
      row_content = %("\\\""  ([^"]*)  "\\\"")
    when .matches?(/^Int/)
      row_content = %("   -?[0-9]+   ")
    when .matches?(/^Float/)
      row_content = %("-?[0-9]+\.[0-9]+")
    when "Bool"
      row_content = %(true | false)
    when "Time" # Creates an ISO8601 timestamp
      row_content = %("\"   [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z   \"")
    else
      row_content = ""
    end

    row_content
  end


  private def deduplicate_any_rows_and_produce_final_output(is_root_object : Bool = false) : IO
    @grammar_output << "root ::= " + @grammar_class.class.to_s + "\n" if is_root_object

    @rows.uniq! { |r| r.row_name } # Remove any duplicates

    main_object_grammar_row = "{"

    is_first_property = true
    @list_of_non_primitive_instance_vars_and_types.each do |ivar|
      if is_first_property
        main_object_grammar_row += "\"#{ivar["property_name"]}\":   #{ivar["property_type"]}  "
        is_first_property = false
      else
        main_object_grammar_row += ", \"#{ivar["property_name"]}\":   #{ivar["property_type"]}  "
      end
    end
    
    @list_of_primitive_instance_vars_and_types.each do |ivar|
      if is_first_property
        main_object_grammar_row += "\"#{ivar["property_name"]}\":   #{ivar["property_type"]}  "
        is_first_property = false
      else
        main_object_grammar_row += ", \"#{ivar["property_name"]}\":   #{ivar["property_type"]}  "
      end
    end
    
    # Set the 2nd row to be the main object grammar for the "root"
    @grammar_output << @grammar_class.class.to_s + " ::= " + main_object_grammar_row + "}\n"

    @grammar_output << @rows.map { |r| r.to_s }.join("\n")
  end
end
