#!/usr/bin/env python3
"""Regenerate the curated Grant tenancy/raw-SQL pair and provenance JSONL files."""

import json
from pathlib import Path
import textwrap

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "training_data" / "amber"
GRANT = Path(__file__).resolve().parents[1] / ".crystal-cache" / "grant-c6b5e72"
GUIDE = Path(__file__).resolve().parents[1] / ".crystal-cache" / "guide-fd988199" / "docs" / "v2" / "guides" / "models" / "grant" / "multi-tenancy.md"
TOPICS = (
    "row_tenancy",
    "schema_tenancy",
    "amber_tenant_pipe",
    "apartment_migration",
    "raw_sql",
    "parity",
)

pairs = []


def model(name, table, fields, *, multitenant=False, associations=(), extra=(), postgres=False):
    lines = [f"class {name} < Grant::Base", f"  table {table}", "", "  column id : Int64, primary: true"]
    lines.extend(f"  column {field}" for field in fields)
    lines.extend(f"  {declaration}" for declaration in associations)
    if multitenant:
        lines.extend(["", "  multitenant :tenant_id"])
    lines.extend(f"  {declaration}" for declaration in extra)
    if postgres:
        lines.extend([
            "",
            "  # This model is configured with PostgreSQL for schema-tenant DDL.",
            "  def self.adapter : Grant::Adapter::Pg",
            "    selected_adapter = super",
            "    if selected_adapter.is_a?(Grant::Adapter::Pg)",
            "      selected_adapter",
            "    else",
            '      raise Grant::UnsupportedSchemaTenantAdapterError.new("This model requires PostgreSQL")',
            "    end",
            "  end",
        ])
    lines.append("end")
    return "\n".join(lines)


def add(topic, prompt, body, symbol, source, *, models=(), amber=False):
    requires = ['require "grant"']
    if "Grant::Adapter::Pg" in body or any("Grant::Adapter::Pg" in item for item in models):
        requires.append('require "grant/adapter/pg"')
    if amber:
        requires.extend(['require "amber"', 'require "http/server"'])
    completion = "\n\n".join([*requires, *models, textwrap.dedent(body).strip()])
    pairs.append({
        "kind": "pair",
        "prompt": prompt,
        "completion": completion,
        "topic": topic,
        "source_symbol": symbol,
        "source_file": str(source),
    })


def tenant_model(name, table, fields, *, associations=()):
    return model(name, table, ["tenant_id : Int64", *fields], multitenant=True, associations=associations)


# Row tenancy: default scope, writes, associations, deliberate cross-tenant work.
TENANT_INVOICE = tenant_model("TenantInvoice", "tenant_invoices", ["account_id : Int64", "invoice_number : String", "invoice_status : String"])
add("row_tenancy", "What declaration makes an invoice model filter automatically by tenant_id?", "Grant::Tenant.with(12_i64) { TenantInvoice.count }", "multitenant", GRANT / "src/grant/scale/tenant.cr", models=[TENANT_INVOICE])
add("row_tenancy", "Show a search for one tenant's invoice without repeating tenant_id in each query.", "Grant::Tenant.with(12_i64) do\n  TenantInvoice.where(invoice_status: \"open\").order(id: :asc).select\nend", "Grant::Tenant.with", GUIDE, models=[TENANT_INVOICE])
add("row_tenancy", "How does a new invoice receive its tenant id when it is created?", "Grant::Tenant.with(12_i64) do\n  TenantInvoice.create!(account_id: 12_i64, invoice_number: \"INV-120\", invoice_status: \"open\")\nend", "multitenant", GRANT / "src/grant/scale/tenant.cr", models=[TENANT_INVOICE])
add("row_tenancy", "Which error protects a row-tenant query that runs without a tenant block?", "# At runtime this unwrapped scoped query raises Grant::NoTenantError.\nTenantInvoice.count", "NoTenantError", GRANT / "src/grant/scale/tenant.cr", models=[TENANT_INVOICE])
add("row_tenancy", "What exception rejects saving an invoice whose tenant_id differs from the current tenant?", "begin\n  Grant::Tenant.with(12_i64) do\n    TenantInvoice.create!(tenant_id: 13_i64, account_id: 13_i64, invoice_number: \"INV-121\", invoice_status: \"open\")\n  end\nrescue ex : Grant::TenantMismatchError\n  false\nend", "TenantMismatchError", GRANT / "src/grant/scale/tenant.cr", models=[TENANT_INVOICE])
add("row_tenancy", "Does a nested tenant block restore the surrounding tenant when it exits?", "Grant::Tenant.with(12_i64) do\n  Grant::Tenant.with(13_i64) { TenantInvoice.where(invoice_status: \"open\").count }\n  TenantInvoice.where(invoice_status: \"open\").count # Scoped again to tenant 12.\nend", "Grant::Tenant.with", GUIDE, models=[TENANT_INVOICE])
TENANT_ACCOUNT = tenant_model("TenantAccount", "tenant_accounts", ["subdomain : String"], associations=['has_many :invoices, class_name: "TenantInvoice", foreign_key: :account_id'])
TENANT_CHILD_INVOICE = tenant_model("TenantInvoice", "tenant_invoices", ["account_id : Int64", "invoice_number : String"], associations=['belongs_to :account, class_name: "TenantAccount"'])
add("row_tenancy", "How do I eager-load invoices without crossing row-tenant boundaries?", "Grant::Tenant.with(12_i64) do\n  TenantAccount.includes(:invoices).where(subdomain: \"acme\").select\nend", "includes", GRANT / "src/grant/eager_loading.cr", models=[TENANT_ACCOUNT, TENANT_CHILD_INVOICE])
add("row_tenancy", "Show a belongs_to association lookup while a row tenant is active.", "Grant::Tenant.with(12_i64) do\n  TenantInvoice.where(account_id: 12_i64).select.each do |invoice|\n    invoice.account\n  end\nend", "belongs_to", GRANT / "src/grant/associations.cr", models=[TENANT_ACCOUNT, TENANT_CHILD_INVOICE])
add("row_tenancy", "Write an admin report that counts open invoices across tenants with the chain form of unscoped.", "# Reserve unscoped for a deliberate cross-tenant admin report.\nTenantInvoice.unscoped.where(invoice_status: \"open\").count", "unscoped", GRANT / "src/grant/scoping.cr", models=[TENANT_INVOICE])
add("row_tenancy", "Use block-form unscoped for a deliberate tenant data repair.", "# Keep this maintenance operation out of request handling.\nTenantInvoice.unscoped do\n  TenantInvoice.where(tenant_id: 0_i64).update_all(tenant_id: 12_i64)\nend", "unscoped", GRANT / "src/grant/scoping.cr", models=[TENANT_INVOICE])
add("row_tenancy", "What should a request use instead of unscoped when loading the current tenant's invoices?", "Grant::Tenant.with(12_i64) do\n  TenantInvoice.where(invoice_status: \"open\").select\nend", "Grant::Tenant.with", GUIDE, models=[TENANT_INVOICE])
add("row_tenancy", "A background fiber does not inherit tenant context; show how it should query invoices.", "tenant_id = 12_i64\nspawn do\n  Grant::Tenant.with(tenant_id) do\n    TenantInvoice.find_each { |invoice| invoice.invoice_number }\n  end\nend", "find_each", GRANT / "src/grant/querying.cr", models=[TENANT_INVOICE])
add("row_tenancy", "Show tenant-scoped batch iteration for a monthly invoice job.", "module TenantInvoicing\n  class CollectMonthlyInvoiceNumbers\n    getter list_of_invoice_numbers : Array(String) = [] of String\n\n    def initialize(@tenant_id : Int64)\n    end\n\n    def perform\n      collect_invoice_numbers_under_tenant_scope\n    end\n\n    private def collect_invoice_numbers_under_tenant_scope\n      Grant::Tenant.with(@tenant_id) do\n        TenantInvoice.find_each do |invoice|\n          @list_of_invoice_numbers << invoice.invoice_number\n        end\n      end\n    end\n  end\nend\n\nTenantInvoicing::CollectMonthlyInvoiceNumbers.new(12_i64).perform", "multitenant", GRANT / "src/grant/scale/tenant.cr", models=[TENANT_INVOICE])
TENANT_JOIN_ACCOUNT = tenant_model("TenantAccount", "tenant_accounts", ["subdomain : String"], associations=['has_many :invoices, class_name: "TenantInvoice", foreign_key: :account_id'])
TENANT_JOIN_INVOICE = tenant_model("TenantInvoice", "tenant_invoices", ["account_id : Int64", "invoice_number : String"], associations=['belongs_to :account, class_name: "TenantAccount"'])
add("row_tenancy", "Do joined account and invoice queries retain the row-tenant filter?", "Grant::Tenant.with(12_i64) do\n  TenantInvoice.joins(:account).where(tenant_id: 12_i64).select\nend", "multitenant", GUIDE, models=[TENANT_JOIN_ACCOUNT, TENANT_JOIN_INVOICE])

# PostgreSQL schema tenancy: lifecycle, public tables, validation, and pinned scopes.
SCHEMA_INVOICE = model("SchemaInvoice", "invoices", ["invoice_number : String", "account_id : Int64"])
SCHEMA_TABLE_INVOICE = model("SchemaInvoice", "invoices", ["invoice_number : String", "account_id : Int64"], postgres=True)
add("schema_tenancy", "How do I run invoice queries inside the acme PostgreSQL schema?", "Grant::SchemaTenant.with(\"acme\") do\n  SchemaInvoice.where(account_id: 12_i64).order(id: :asc).select\nend", "Grant::SchemaTenant.with", GUIDE, models=[SCHEMA_INVOICE])
PUBLIC_PLAN = model("PublicPlan", "plans", ["plan_code : String"], extra=["schema_tenant_excluded"])
PUBLIC_PLAN_DDL = model("PublicPlan", "plans", ["plan_code : String"], extra=["schema_tenant_excluded"], postgres=True)
add("schema_tenancy", "Which model declaration keeps a shared plans table in public for every schema tenant?", "Grant::SchemaTenant.with(\"acme\") do\n  PublicPlan.find_by(plan_code: \"pro\")\nend", "schema_tenant_excluded", GRANT / "src/grant/scale/schema_tenant.cr", models=[PUBLIC_PLAN])
add("schema_tenancy", "Create the acme tenant schema if it does not exist yet.", "Grant::SchemaTenant.create_schema(\"acme\")", "create_schema", GRANT / "src/grant/scale/schema_tenant.cr")
SCHEMA_PAYMENT = model("SchemaPayment", "payments", ["amount_cents : Int64", "invoice_id : Int64"], postgres=True)
SCHEMA_LINE = model("SchemaLine", "invoice_lines", ["invoice_id : Int64", "description : String"], postgres=True)
add("schema_tenancy", "After creating a schema, create its invoice and payment tables.", "Grant::SchemaTenant.create_schema(\"acme\")\nGrant::SchemaTenant.create_tables(\"acme\", SchemaInvoice, SchemaPayment, SchemaLine)", "create_tables", GRANT / "src/grant/scale/schema_tenant.cr", models=[SCHEMA_TABLE_INVOICE, SCHEMA_PAYMENT, SCHEMA_LINE])
add("schema_tenancy", "List tenant schemas while excluding PostgreSQL system schemas and public.", "list_of_schemas = Grant::SchemaTenant.list_schemas\nlist_of_schemas.each { |schema| schema.downcase }", "list_schemas", GRANT / "src/grant/scale/schema_tenant.cr")
add("schema_tenancy", "Drop the acme schema and its contained database objects.", "Grant::SchemaTenant.drop_schema(\"acme\", cascade: true)", "drop_schema", GRANT / "src/grant/scale/schema_tenant.cr")
add("schema_tenancy", "How should code handle an invalid or reserved PostgreSQL schema name?", "begin\n  Grant::SchemaTenant.create_schema(\"pg_reserved\")\nrescue ex : Grant::InvalidSchemaNameError\n  false\nend", "InvalidSchemaNameError", GRANT / "src/grant/scale/schema_tenant.cr")
add("schema_tenancy", "Inside a tenant schema, query a shared table that lives in public.", "Grant::SchemaTenant.with(\"acme\") do\n  Grant.connection.select_all(\"SELECT id, plan_code FROM public.plans WHERE plan_code = ?\", [\"pro\"])\nend", "public.", GUIDE)
add("schema_tenancy", "Can a subdomain be inserted directly into SET search_path SQL? Use Grant's validated schema scope.", "Grant::SchemaTenant.with(\"acme\") do\n  SchemaInvoice.where(account_id: 12_i64).select\nend", "Grant::SchemaTenant.with", GUIDE, models=[SCHEMA_INVOICE])
SCHEMA_ACCOUNT = model("SchemaAccount", "accounts", ["subdomain : String"], associations=['has_many :invoices, class_name: "SchemaInvoice", foreign_key: :account_id'])
SCHEMA_CHILD_INVOICE = model("SchemaInvoice", "invoices", ["account_id : Int64", "invoice_number : String"], associations=['belongs_to :account, class_name: "SchemaAccount"'])
add("schema_tenancy", "Do eager-loaded invoices use the same schema connection as their account?", "Grant::SchemaTenant.with(\"acme\") do\n  SchemaAccount.includes(:invoices).where(subdomain: \"acme\").select\nend", "Grant::SchemaTenant.with", GUIDE, models=[SCHEMA_ACCOUNT, SCHEMA_CHILD_INVOICE])
add("schema_tenancy", "How should a global model's public table be created once rather than once per tenant?", "Grant::SchemaTenant.create_schema(\"acme\")\nPublicPlan.migrator.create", "schema_tenant_excluded", GRANT / "src/grant/scale/schema_tenant.cr", models=[PUBLIC_PLAN_DDL])
add("schema_tenancy", "What should a PostgreSQL schema-tenant setup do when the selected adapter is SQLite?", "begin\n  Grant::SchemaTenant.create_schema(\"acme\")\nrescue ex : Grant::UnsupportedSchemaTenantAdapterError\n  false\nend", "UnsupportedSchemaTenantAdapterError", GRANT / "src/grant/scale/schema_tenant.cr")
add("schema_tenancy", "Where should search_path reset happen after a tenant block raises?", "Grant::SchemaTenant.with(\"acme\") { SchemaInvoice.count }", "Grant::SchemaTenant.with", GUIDE, models=[SCHEMA_INVOICE])
add("schema_tenancy", "Show a maintenance pass that visits each schema inside its own bounded block.", "Grant::SchemaTenant.list_schemas.each do |schema|\n  Grant::SchemaTenant.with(schema) { SchemaInvoice.count }\nend", "list_schemas", GRANT / "src/grant/scale/schema_tenant.cr", models=[SCHEMA_INVOICE])

# Amber V2 handler and route-pipeline examples. Every completion exercises call(context).
def tenant_pipe(name, *, schema=False, valves=("web",), include_session=False, include_csrf=False, explicit_account=True):
    account_name = f"{name}Account"
    pipe_name = f"{name}::ResolveSchemaTenantFromSubdomain" if schema else f"{name}::ResolveRowTenantFromSubdomain"
    fields = ["subdomain : String"]
    if schema:
        fields.append("schema_name : String")
    account = model(account_name, f"{name.lower()}_accounts", fields, extra=["schema_tenant_excluded"] if schema else ())
    tenant_block = f'Grant::SchemaTenant.with(account.schema_name) {{ call_next(context) }}' if schema else 'Grant::Tenant.with(account.id) { call_next(context) }'
    class_name = "ResolveSchemaTenantFromSubdomain" if schema else "ResolveRowTenantFromSubdomain"
    pipe = f'''module {name}
  class {class_name}
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      host = context.request.headers["Host"]?.try(&.split(":", 2).first)
      subdomain = host.try {{ |value| value.split(".").first if value.count(".") >= 2 }}

      unless subdomain && (account = {account_name}.find_by(subdomain: subdomain))
        context.response.respond_with_status(:not_found)
        return
      end

      {tenant_block}
    end
  end
end'''
    plugs = []
    if include_session:
        plugs.append("    plug Amber::Pipe::Session.new")
    plugs.extend([f"    plug {pipe_name}.new"])
    if include_csrf:
        plugs.append("    plug Amber::Pipe::CSRF.new")
    pipelines = []
    for valve in valves:
        pipelines.append("  pipeline :" + valve + " do\n" + "\n".join(plugs) + "\n  end")
    config = "Amber::Server.configure do\n" + "\n\n".join(pipelines) + "\nend"
    probe = f'''request = HTTP::Request.new("GET", "/")
request.headers["Host"] = "acme.example.test"
context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
{pipe_name}.new.call(context)'''
    return account, pipe + "\n\n" + config + "\n\n" + probe

HANDLER_GUIDE = GUIDE
for prompt, name, schema, valves, session, csrf in [
    ("Write an Amber HTTP::Handler that resolves an account subdomain and scopes call_next to its row tenant.", "RequestTenant", False, ("web",), False, False),
    ("How can an Amber pipe route requests for an account to its PostgreSQL schema?", "SchemaRequestTenant", True, ("web",), False, False),
    ("Reject a request when Host has no account subdomain before entering Grant::Tenant.with.", "HostTenant", False, ("web",), False, False),
    ("Parse the hostname without its port, look up the account, then wrap the downstream handler.", "PortAwareTenant", False, ("web",), False, False),
    ("Add the row-tenant pipe to Amber's web routes pipeline.", "WebTenant", False, ("web",), True, True),
    ("Wire the tenant pipe into both web and API request pipelines.", "BothTenant", False, ("web", "api"), True, True),
    ("Where should an Amber tenant pipe go relative to the session and CSRF pipes?", "OrderedTenant", False, ("web",), True, True),
    ("Use a global account lookup before switching to a schema tenant in an Amber pipe.", "GlobalAccountTenant", True, ("web",), False, False),
    ("Write a tenant pipe that returns 404 for an unknown subdomain and never trusts the hostname alone.", "VerifiedHostTenant", False, ("api",), False, False),
    ("Configure an Amber API pipeline to wrap every downstream request in the resolved row tenant.", "ApiTenant", False, ("api",), True, False),
    ("Show schema tenancy in middleware while leaving the Account model in public.", "PublicAccountTenant", True, ("web",), True, True),
    ("How should a request without a Host header fail in an Amber tenant handler?", "MissingHostTenant", False, ("web",), False, False),
    ("Place tenant resolution after the session and before CSRF for the web pipeline.", "SessionTenant", False, ("web",), True, True),
    ("Define the subdomain pipe and configure Amber::Server with a tenant-aware web pipeline.", "ConfiguredTenant", False, ("web",), True, False),
]:
    account_code, handler_code = tenant_pipe(name, schema=schema, valves=valves, include_session=session, include_csrf=csrf)
    add("amber_tenant_pipe", prompt, handler_code, "Grant::SchemaTenant.with" if schema else "Grant::Tenant.with", HANDLER_GUIDE, models=[account_code], amber=True)

# Apartment-to-Grant migration. Rails forms are labeled comments beside compiling Grant code.
MIGRATION_SCHEMA_INVOICE = model("ApartmentInvoice", "invoices", ["invoice_number : String"])
add("apartment_migration", "Map Apartment::Tenant.switch(\"acme\") to a bounded Grant schema block.", "# Rails/Apartment: Apartment::Tenant.switch(\"acme\") { Invoice.count }\nGrant::SchemaTenant.with(\"acme\") { ApartmentInvoice.count }", "Grant::SchemaTenant.with", GUIDE, models=[MIGRATION_SCHEMA_INVOICE])
add("apartment_migration", "What replaces Apartment::Tenant.switch! when Grant scopes tenant state?", "# Rails/Apartment: Apartment::Tenant.switch!(\"acme\")\n# Grant bounds schema state to this block.\nGrant::SchemaTenant.with(\"acme\") { ApartmentInvoice.count }", "Grant::SchemaTenant.with", GUIDE, models=[MIGRATION_SCHEMA_INVOICE])
add("apartment_migration", "Map Apartment::Tenant.current to Grant's current schema accessor.", "Grant::SchemaTenant.with(\"acme\") do\n  active_schema = Grant::SchemaTenant.current_schema\n  active_schema if active_schema\nend", "current_schema", GRANT / "src/grant/scale/schema_tenant.cr", models=[MIGRATION_SCHEMA_INVOICE])
SCHEMA_SETUP_INVOICE = model("SetupInvoice", "invoices", ["invoice_number : String"], postgres=True)
SCHEMA_SETUP_PAYMENT = model("SetupPayment", "payments", ["amount_cents : Int64"], postgres=True)
add("apartment_migration", "Replace Apartment::Tenant.create with schema creation and per-tenant table creation.", "# Rails/Apartment: Apartment::Tenant.create(\"acme\")\nGrant::SchemaTenant.create_schema(\"acme\")\nGrant::SchemaTenant.create_tables(\"acme\", SetupInvoice, SetupPayment)", "create_schema", GUIDE, models=[SCHEMA_SETUP_INVOICE, SCHEMA_SETUP_PAYMENT])
add("apartment_migration", "Map Apartment::Tenant.drop while removing that tenant's tables too.", "# Rails/Apartment: Apartment::Tenant.drop(\"acme\")\nGrant::SchemaTenant.drop_schema(\"acme\", cascade: true)", "drop_schema", GUIDE)
add("apartment_migration", "What Grant call lists schema tenants instead of Apartment.tenant_names?", "# Rails/Apartment: Apartment.tenant_names\nGrant::SchemaTenant.list_schemas.each { |schema| schema.downcase }", "list_schemas", GUIDE)
PUBLIC_USER = model("PublicUser", "users", ["email_address : String"], extra=["schema_tenant_excluded"])
add("apartment_migration", "Replace config.excluded_models for a User model that stays in public.", "# Rails/Apartment: config.excluded_models = [\"User\"]\nGrant::SchemaTenant.with(\"acme\") { PublicUser.find_by(email_address: \"a@example.test\") }", "schema_tenant_excluded", GUIDE, models=[PUBLIC_USER])
MIGRATION_ACCOUNT = model("MigrationAccount", "accounts", ["subdomain : String", "schema_name : String"], extra=["schema_tenant_excluded"])
add("apartment_migration", "Map Apartment's subdomain elevator to an Amber pipe that resolves the account first.", "module ApartmentMigration\n  class ResolveSchemaTenantFromSubdomain\n    include HTTP::Handler\n\n    def call(context : HTTP::Server::Context)\n      host = context.request.headers[\"Host\"]?.try(&.split(\":\", 2).first)\n      subdomain = host.try { |value| value.split(\".\").first if value.count(\".\") >= 2 }\n      if subdomain && (account = MigrationAccount.find_by(subdomain: subdomain))\n        Grant::SchemaTenant.with(account.schema_name) { call_next(context) }\n      else\n        context.response.respond_with_status(:not_found)\n      end\n    end\n  end\nend", "Grant::SchemaTenant.with", GUIDE, models=[MIGRATION_ACCOUNT], amber=True)
add("apartment_migration", "If the existing PostgreSQL tenant schemas should stay intact, how should Grant query one?", "# Point Grant at the existing PostgreSQL database, then keep the schema name.\nGrant::SchemaTenant.with(\"acme\") { ApartmentInvoice.where(invoice_number: \"INV-1\").first }", "Grant::SchemaTenant.with", GUIDE, models=[MIGRATION_SCHEMA_INVOICE])
add("apartment_migration", "How should a Grant job restore tenant scope after leaving the request fiber?", "module SchemaTenantMaintenance\n  class CountTenantInvoices\n    def initialize(@schema_name : String)\n    end\n\n    def perform\n      count_invoices_inside_schema_scope\n    end\n\n    private def count_invoices_inside_schema_scope\n      Grant::SchemaTenant.with(@schema_name) { ApartmentInvoice.count }\n    end\n  end\nend\n\nSchemaTenantMaintenance::CountTenantInvoices.new(\"acme\").perform", "Grant::SchemaTenant.with", GUIDE, models=[MIGRATION_SCHEMA_INVOICE])
ROW_MIGRATION_INVOICE = tenant_model("SharedInvoice", "shared_invoices", ["invoice_number : String"])
add("apartment_migration", "Show the Grant row-tenancy form when moving from one shared table per tenant schema.", "# Apartment keeps a schema per tenant. Row tenancy uses a shared table plus tenant_id.\nGrant::Tenant.with(12_i64) { SharedInvoice.where(invoice_number: \"INV-1\").select }", "multitenant", GRANT / "src/grant/scale/tenant.cr", models=[ROW_MIGRATION_INVOICE])
add("apartment_migration", "When consolidating tenant schemas into row tenancy, how can a migration map old IDs to new IDs?", "list_of_invoice_id_mappings_as_hash = {} of Int64 => Int64\nGrant::SchemaTenant.with(\"acme\") do\n  ApartmentInvoice.find_each do |legacy_invoice|\n    legacy_invoice_id = legacy_invoice.id\n    unless legacy_invoice_id\n      raise \"legacy invoice has no id\"\n    end\n    migrated_invoice = Grant::Tenant.with(12_i64) do\n      SharedInvoice.create!(invoice_number: legacy_invoice.invoice_number)\n    end\n    migrated_invoice_id = migrated_invoice.id\n    unless migrated_invoice_id\n      raise \"migrated invoice has no id\"\n    end\n    list_of_invoice_id_mappings_as_hash[legacy_invoice_id] = migrated_invoice_id\n  end\nend\nlist_of_invoice_id_mappings_as_hash", "multitenant", GUIDE, models=[MIGRATION_SCHEMA_INVOICE, ROW_MIGRATION_INVOICE])
add("apartment_migration", "Mark a shared plans table as global when migrating Apartment excluded models.", "# Rails/Apartment: config.excluded_models = [\"Plan\"]\nclass MigrationPlan < Grant::Base\n  table plans\n  column id : Int64, primary: true\n  column plan_code : String\n  schema_tenant_excluded\nend\n\nGrant::SchemaTenant.with(\"acme\") { MigrationPlan.find_by(plan_code: \"pro\") }", "schema_tenant_excluded", GUIDE)
add("apartment_migration", "Show the Grant replacement for an Apartment schema switch around a query.", "# Rails/Apartment: Apartment::Tenant.switch(\"acme\") { Invoice.where(invoice_number: \"INV-2\").first }\nGrant::SchemaTenant.with(\"acme\") do\n  ApartmentInvoice.where(invoice_number: \"INV-2\").first\nend", "Grant::SchemaTenant.with", GUIDE, models=[MIGRATION_SCHEMA_INVOICE])

# Raw SQL: hydration, results, bound writes and reads, tenancy limits, and injection safety.
RAW_POST = model("RawPost", "posts", ["author_id : Int64", "post_title : String", "post_status : String"])
add("raw_sql", "Use raw SQL to hydrate Grant Post models for one author.", "RawPost.find_by_sql(\"SELECT * FROM posts WHERE author_id = ? ORDER BY id\", [12_i64])", "find_by_sql", GRANT / "src/grant/querying.cr", models=[RAW_POST])
add("raw_sql", "Count matching rows with bound parameters and get an Int64 from Grant.", "RawPost.count_by_sql(\"SELECT COUNT(*) FROM posts WHERE author_id = ?\", [12_i64])", "count_by_sql", GRANT / "src/grant/querying.cr", models=[RAW_POST])
add("raw_sql", "How do I read raw rows from a model connection with exec_query?", "connection = RawPost.connection\nresult = connection.exec_query(\"SELECT id, post_title FROM posts WHERE author_id = ?\", [12_i64])\nresult.columns\nresult.to_a", "exec_query", GRANT / "src/grant/connection.cr", models=[RAW_POST])
add("raw_sql", "Show the bound write-connection execute method and its affected-row result.", "result = RawPost.connection.execute(\"UPDATE posts SET post_status = ? WHERE id = ?\", [\"published\", 5_i64])\nresult.rows_affected", "execute", GRANT / "src/grant/connection.cr", models=[RAW_POST])
add("raw_sql", "What does exec_query return, and how can I read its buffered columns and positional rows?", "# exec_query returns Grant::Result; leave its adapter-normalized value types inferred.\nresult = RawPost.connection.exec_query(\"SELECT id, post_title FROM posts\")\nresult.columns\nresult.rows.each { |row| row.first }", "Grant::Result", GRANT / "docs/querying.md", models=[RAW_POST])
add("raw_sql", "Use select_all when several result rows are expected.", "result = RawPost.connection.select_all(\"SELECT id, post_title FROM posts WHERE post_status = ?\", [\"draft\"])\nresult.each { |row| row[\"post_title\"] }", "select_all", GRANT / "src/grant/connection.cr", models=[RAW_POST])
add("raw_sql", "Handle the optional first row returned by select_one without asserting non-nil.", "row = RawPost.connection.select_one(\"SELECT id, post_title FROM posts WHERE id = ?\", [5_i64])\nif first_row = row\n  first_row[\"post_title\"]\nend", "select_one", GRANT / "src/grant/connection.cr", models=[RAW_POST])
add("raw_sql", "Read the first result cell safely when select_value might return nil.", "value = RawPost.connection.select_value(\"SELECT post_title FROM posts WHERE id = ?\", [5_i64])\nif selected_post_title = value\n  selected_post_title.to_s\nend", "select_value", GRANT / "src/grant/connection.cr", models=[RAW_POST])
add("raw_sql", "Get the first selected column from every row using select_values.", "list_of_post_titles = RawPost.connection.select_values(\"SELECT post_title FROM posts WHERE author_id = ? ORDER BY id\", [12_i64])\nlist_of_post_titles.each { |post_title| post_title.to_s }", "select_values", GRANT / "src/grant/connection.cr", models=[RAW_POST])
add("raw_sql", "Read positional result rows from a Grant connection.", "list_of_rows = RawPost.connection.select_rows(\"SELECT id, post_title FROM posts ORDER BY id\")\nlist_of_rows.each { |row| row.first }", "select_rows", GRANT / "src/grant/connection.cr", models=[RAW_POST])
add("raw_sql", "Execute SQL on the named analytics connection rather than the model's default database.", "analytics = Grant.connection(\"analytics\")\nanalytics.execute(\"DELETE FROM old_events WHERE created_at < ?\", [Time.utc])\nanalytics.select_all(\"SELECT id FROM daily_totals\")", "Grant.connection", GRANT / "docs/querying.md")
add("raw_sql", "Update one post with Model.exec and a bound status value.", "RawPost.exec(\"UPDATE posts SET post_status = ? WHERE id = ?\", [\"published\", 5_i64])", "exec", GRANT / "src/grant/querying.cr", models=[RAW_POST])
add("raw_sql", "Read one scalar value through the model's bound scalar helper.", "post_title = RawPost.scalar(\"SELECT post_title FROM posts WHERE id = ?\", [5_i64])\nif selected_post_title = post_title\n  selected_post_title.to_s\nend", "scalar", GRANT / "src/grant/querying.cr", models=[RAW_POST])
add("raw_sql", "Build a quoted SQL condition with sanitize_sql_array, then prefer a bound query for execution.", "post_title = \"O'Reilly\"\ncondition = RawPost.sanitize_sql_array([\"post_title = ?\", post_title])\nRawPost.connection.select_all(\"SELECT id FROM posts WHERE post_title = ?\", [post_title])\ncondition", "sanitize_sql_array", GRANT / "src/grant/querying.cr", models=[RAW_POST])
SCOPED_INVOICE = model("ScopedInvoice", "invoices", ["tenant_id : Int64", "invoice_number : String"], multitenant=True)
add("raw_sql", "What does Grant raise when raw SQL is called on a scoped model outside unscoped?", "# Raw model SQL does not apply the default tenant predicate.\nbegin\n  ScopedInvoice.find_by_sql(\"SELECT * FROM invoices\")\nrescue ex : Grant::Querying::ScopedRawSqlError\n  [] of ScopedInvoice\nend", "ScopedRawSqlError", GRANT / "src/grant/querying.cr", models=[SCOPED_INVOICE])
add("raw_sql", "Run find_by_sql deliberately on a scoped model while still binding the tenant predicate yourself.", "Grant::Tenant.with(12_i64) do\n  ScopedInvoice.unscoped do\n    ScopedInvoice.find_by_sql(\"SELECT * FROM invoices WHERE tenant_id = ?\", [12_i64])\n  end\nend", "find_by_sql", GUIDE, models=[SCOPED_INVOICE])
add("raw_sql", "Why must a raw connection query add its own tenant predicate even inside Grant::Tenant.with?", "Grant::Tenant.with(12_i64) do\n  # Model.connection is raw; bind the tenant predicate yourself.\n  ScopedInvoice.connection.exec_query(\"SELECT id, invoice_number FROM invoices WHERE tenant_id = ?\", [12_i64])\nend", "Model.connection", GUIDE, models=[SCOPED_INVOICE])
add("raw_sql", "Show a PostgreSQL numbered placeholder with its separate bound value.", "author_id = 12_i64\nRawPost.connection.exec_query(\"SELECT id FROM posts WHERE author_id = $1\", [author_id])", "exec_query", GRANT / "docs/querying.md", models=[RAW_POST])
add("raw_sql", "Contrast unsafe interpolation with a bound parameter for a user-supplied title.", "# WRONG: \"SELECT * FROM posts WHERE post_title = '#{unsafe_post_title}'\"\nuser_post_title = \"sample\"\nRawPost.find_by_sql(\"SELECT * FROM posts WHERE post_title = ?\", [user_post_title])", "find_by_sql", GRANT / "docs/querying.md", models=[RAW_POST])
add("raw_sql", "How do raw model SQL calls differ from Model.connection calls on a multitenant model?", "Grant::Tenant.with(12_i64) do\n  # Model.connection is raw and never injects tenant_id, so bind it explicitly.\n  ScopedInvoice.connection.select_all(\"SELECT id FROM invoices WHERE tenant_id = ?\", [12_i64])\nend", "Model.connection", GUIDE, models=[SCOPED_INVOICE])

# Parity answers state only the status recorded in the checked-in tracker.
PARITY = GRANT / "docs/PARITY.md"
add("parity", "Does Grant support row-level tenant scoping like ActiveRecord?", "# docs/PARITY.md marks row-level multi-tenancy as complete.\nGrant::Tenant.with(12_i64) { ParityInvoice.count }", "Row-level multi-tenancy", PARITY, models=[tenant_model("ParityInvoice", "parity_invoices", ["invoice_number : String"])])
add("parity", "Is PostgreSQL schema-per-tenant switching complete in this Grant parity tracker?", "# docs/PARITY.md marks PostgreSQL schema-per-tenant switching complete.\nGrant::SchemaTenant.with(\"acme\") { ParityInvoice.count }", "schema-per-tenant switching", PARITY, models=[model("ParityInvoice", "invoices", ["invoice_number : String"])])
add("parity", "Does Grant have an HABTM association macro?", "# docs/PARITY.md marks the HABTM equivalent missing.\n# Model the join row explicitly; do not call a nonexistent HABTM macro.\nclass BookAuthorLink < Grant::Base\n  table book_authors\n  column id : Int64, primary: true\n  column book_id : Int64\n  column author_id : Int64\nend\n\nBookAuthorLink.where(book_id: 4_i64).select", "HABTM", PARITY)
add("parity", "Is ActiveRecord's association-only where.has or where.missing interface fully supported?", "# docs/PARITY.md marks where.missing/where.has partial: Grant requires\n# explicit table and foreign_key arguments.\nParityArticle.find_by_sql(\"SELECT articles.* FROM articles LEFT JOIN comments ON comments.article_id = articles.id WHERE comments.id IS NULL AND articles.id = ?\", [4_i64])", "where.has", PARITY, models=[model("ParityArticle", "articles", ["article_title : String"])])
add("parity", "Does Grant provide an integrated, versioned migration runner like Rails?", "# docs/PARITY.md marks the Grant::Migrator CREATE TABLE DSL partial;\n# version tracking is delegated to an external migration tool.\nclass ParityInvoice < Grant::Base\n  table invoices\n  column id : Int64, primary: true\n  column invoice_number : String\n\n  # This model is configured with PostgreSQL for schema DDL.\n  def self.adapter : Grant::Adapter::Pg\n    selected_adapter = super\n    if selected_adapter.is_a?(Grant::Adapter::Pg)\n      selected_adapter\n    else\n      raise Grant::UnsupportedSchemaTenantAdapterError.new(\"This model requires PostgreSQL\")\n    end\n  end\nend\n\nParityInvoice.migrator.create", "Grant::Migrator", PARITY)
add("parity", "Does Grant have an ActiveRecord-style query cache?", "# docs/PARITY.md marks query cache missing; do not claim repeated queries are cached.\nParityPost.connection.select_value(\"SELECT COUNT(*) FROM posts\")", "query cache", PARITY, models=[model("ParityPost", "posts", ["post_title : String"])])
add("parity", "Is the Amber database migration CLI fully integrated into Grant?", "# docs/PARITY.md marks the Migration CLI partial: it lives outside Grant.\nclass ParityPayment < Grant::Base\n  table payments\n  column id : Int64, primary: true\n  column amount_cents : Int64\n\n  # This model is configured with PostgreSQL for schema DDL.\n  def self.adapter : Grant::Adapter::Pg\n    selected_adapter = super\n    if selected_adapter.is_a?(Grant::Adapter::Pg)\n      selected_adapter\n    else\n      raise Grant::UnsupportedSchemaTenantAdapterError.new(\"This model requires PostgreSQL\")\n    end\n  end\nend\n\nParityPayment.migrator.create", "Migration CLI", PARITY)
add("parity", "Are Grant raw connection reads and Grant::Result recorded as complete?", "# docs/PARITY.md marks raw connection execute/exec_query and Grant::Result complete.\nresult = Grant.connection.exec_query(\"SELECT id, title FROM posts\")\nresult.columns\nresult.to_a", "Grant::Result", PARITY)

if len(pairs) != 84:
    raise SystemExit(f"expected 84 pairs, built {len(pairs)}")
counts = {topic: sum(row["topic"] == topic for row in pairs) for topic in TOPICS}
if len({row["prompt"].casefold() for row in pairs}) != len(pairs):
    raise SystemExit("duplicate prompt in curated pairs")

for output_name, keys in (
    ("grant_tenancy_rawsql_pairs.jsonl", ("kind", "prompt", "completion")),
    ("grant_tenancy_rawsql_provenance.jsonl", ("topic", "prompt", "completion", "source_symbol", "source_file")),
):
    path = OUT / output_name
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        for row in pairs:
            output = {key: row[key] for key in keys if key in row}
            stream.write(json.dumps(output, ensure_ascii=False, separators=(",", ":")) + "\n")

print(f"wrote {len(pairs)} pairs: " + ", ".join(f"{topic}={count}" for topic, count in counts.items()))
