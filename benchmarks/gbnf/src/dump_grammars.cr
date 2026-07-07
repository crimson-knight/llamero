require "llamero"
require "./schemas"

Dir.mkdir_p("results/grammars")
File.write("results/grammars/flat_invoice.gbnf", FlatInvoice.to_gbnf)
File.write("results/grammars/contact_card.gbnf", ContactCard.to_gbnf)
File.write("results/grammars/cliff_ticket.gbnf", CliffTicket.to_gbnf)
puts "flat=#{FlatInvoice.to_gbnf.bytesize}B medium=#{ContactCard.to_gbnf.bytesize}B cliff=#{CliffTicket.to_gbnf.bytesize}B"
# longest line = the subset alternation; count its variants
cliff = CliffTicket.to_gbnf
longest = cliff.lines.max_by(&.size)
puts "cliff longest rule: #{longest.split(" ::= ").first} with #{longest.count('|') + 1} alternatives, #{longest.bytesize} bytes"
