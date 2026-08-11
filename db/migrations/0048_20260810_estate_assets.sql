-- db/migrations/0048_20260810_estate_assets.sql
--
-- PHASE 9 — the MANUAL estate asset inventory. An owner records what the estate actually consists of:
-- accounts, property, business interests, digital assets and physical valuables — without any
-- dependency on financial aggregation.
--
-- ★ WHY THIS IS A NEW TABLE AND NOT A COLUMN ON normalized_assets.
--   `normalized_assets` (0007) is AGGREGATOR-SHAPED and aggregator-OWNED:
--     * `connection_id` is NOT NULL and FKs to `connections`, so a manual asset has no legal row;
--     * a connection refresh performs DELETE + INSERT for the connection's rows, so anything manual
--       parked there would be destroyed by a Plaid sync — silently, and only for users who happen to
--       link an account.
--   Manual assets are therefore first-class in their own table, exactly as the product treats them.
--
-- ★ AAL2 POSTURE — OWNER-APPROVED RULING (Phase 9), AND IT LOOSENS NOTHING.
--   `list_estate_assets` keeps `require_aal2()` for aggregator-sourced exact values: UNCHANGED.
--   Cross-person disclosure keeps its gate: UNCHANGED (and no non-owner can read this table at all —
--   see the RLS note below). What is new is that an owner may read the values THEY THEMSELVES TYPED
--   at aal1, because re-proving identity to read back your own typing protects nothing, and the app
--   has no in-app TOTP enrollment flow, so the alternative was an enrollment wall in front of the
--   MVP's core feature.
--
-- ★ NON-OWNERS SEE NOTHING HERE, DELIBERATELY, AND THAT IS THE WHOLE PHASE-9 DISCLOSURE STORY FOR
--   MANUAL ASSETS. `access_grants` scopes a grant by an XOR of `document_id` / `category`; adding an
--   asset scope means altering that XOR and the write-time ceiling trigger keyed on `document_id` —
--   a change to the security-critical centre of the disclosure model. That is NOT smuggled into an
--   inventory slice. Manual assets are owner-only until per-asset grants are designed on their own
--   merits. Default-deny is the safe direction, and it is enforced structurally by RLS.
--
-- ★ DELETION — OWNER-APPROVED RULING (Phase 9): SOFT delete (archive) with restore. Documents keep
--   their locked HARD-delete design because their irreversibility is justified by a storage-byte
--   purge; a manual asset has no bytes of its own, so an accidental deletion during bulk inventory
--   entry is recoverable. Archiving an asset detaches no document and purges nothing.
--
-- Idempotent; safe to re-run.

begin;

-- =============================================================================================
-- 1 · estate_asset_category — the COARSE server-authoritative vocabulary
-- =============================================================================================
-- Born clean, exactly like `document_subtype` (0036): RLS on, NO client grants. The read path is
-- get_estate_asset_taxonomy(). A client union here would be a second source of truth that drifts the
-- moment a category is added — the taxonomy rule this codebase learned from `subtype: 'other'`.
create table if not exists public.estate_asset_category (
  value        text        primary key,
  display_name text        not null,
  description  text,
  sort_order   int         not null default 0,
  icon_key     text,
  -- PRESENTATION metadata only, never authorization: it tells the client which optional fields are
  -- worth offering (a location hint for a ring, an institution for a brokerage account).
  is_physical  boolean     not null default false,
  is_active    boolean     not null default true,
  created_at   timestamptz not null default now()
);
alter table public.estate_asset_category enable row level security;

-- =============================================================================================
-- 2 · estate_asset_subtype — the FINE vocabulary, parented to a category
-- =============================================================================================
-- Mirrors document_subtype → document_type: persist-both, so a client that does not recognise a new
-- subtype can still group by its parent category rather than losing the row.
create table if not exists public.estate_asset_subtype (
  subtype         text        primary key,
  parent_category text        not null references public.estate_asset_category(value),
  display_name    text        not null,
  description     text,
  sort_order      int         not null default 0,
  icon_key        text,
  is_active       boolean     not null default true,
  created_at      timestamptz not null default now()
);
create index if not exists estate_asset_subtype_parent_idx
  on public.estate_asset_subtype (parent_category);
alter table public.estate_asset_subtype enable row level security;

-- =============================================================================================
-- 3 · SEED — the nine categories from the product definition
-- =============================================================================================
insert into public.estate_asset_category (value, display_name, description, sort_order, icon_key, is_physical) values
  ('bankAccount',      'Bank or financial account', 'Chequing, savings, term deposits and similar cash holdings.', 1, 'financial', false),
  ('investment',       'Investment',                'Brokerage accounts and directly held securities.',            2, 'financial', false),
  ('retirement',       'Retirement or pension',     'Workplace pensions, personal retirement accounts, annuities.', 3, 'financial', false),
  ('insurance',        'Insurance',                 'Policies that pay out to the estate or to a named person.',   4, 'authority', false),
  ('realEstate',       'Real estate',               'Land and buildings, wherever they are held.',                  5, 'property',  false),
  ('businessInterest', 'Business interest',         'Ownership in a company, partnership or practice.',             6, 'authority', false),
  ('digitalAsset',     'Crypto or digital asset',   'Exchange accounts, self-custody wallets and digital property.', 7, 'financial', false),
  ('physicalValuable', 'Physical valuable',         'Items whose value is in the object itself.',                   8, 'property',  true),
  ('otherAsset',       'Other asset',               'Anything the other categories do not describe.',               9, 'document',  false)
on conflict (value) do update set
  display_name = excluded.display_name,
  description  = excluded.description,
  sort_order   = excluded.sort_order,
  icon_key     = excluded.icon_key,
  is_physical  = excluded.is_physical;

-- =============================================================================================
-- 4 · SEED — subtypes. `customAsset` is the GENERIC entry, the analogue of `customDocument`.
-- =============================================================================================
-- ★ THE GENERIC ENTRY EXISTS SO THE CLIENT NEVER HAS TO INVENT ONE. The Vault defect was a client
-- sending a value the catalog did not contain; a resolvable generic is what makes "I don't know what
-- this is" expressible IN the vocabulary instead of beside it.
insert into public.estate_asset_subtype (subtype, parent_category, display_name, sort_order) values
  ('chequingAccount',       'bankAccount',      'Chequing account',            1),
  ('savingsAccount',        'bankAccount',      'Savings account',             2),
  ('moneyMarketAccount',    'bankAccount',      'Money market account',        3),
  ('termDeposit',           'bankAccount',      'Term deposit or GIC/CD',      4),

  ('brokerageAccount',      'investment',       'Brokerage account',           1),
  ('directEquity',          'investment',       'Directly held shares',        2),
  ('bondHolding',           'investment',       'Bonds',                       3),
  ('fundHolding',           'investment',       'Mutual or index funds',       4),

  ('workplacePension',      'retirement',       'Workplace pension',           1),
  ('personalRetirement',    'retirement',       'Personal retirement account', 2),
  ('annuityContract',       'retirement',       'Annuity',                     3),

  ('lifeInsurance',         'insurance',        'Life insurance policy',       1),
  ('criticalIllnessCover',  'insurance',        'Critical illness cover',      2),
  ('longTermCareCover',     'insurance',        'Long-term care cover',        3),

  ('primaryResidence',      'realEstate',       'Primary residence',           1),
  ('secondaryProperty',     'realEstate',       'Second or holiday property',  2),
  ('rentalProperty',        'realEstate',       'Rental property',             3),
  ('landParcel',            'realEstate',       'Land',                        4),

  ('soleProprietorship',    'businessInterest', 'Sole proprietorship',         1),
  ('partnershipInterest',   'businessInterest', 'Partnership interest',        2),
  ('privateCompanyShares',  'businessInterest', 'Private company shares',      3),

  ('exchangeAccount',       'digitalAsset',     'Exchange account',            1),
  ('selfCustodyWallet',     'digitalAsset',     'Self-custody wallet',         2),
  ('digitalCollectible',    'digitalAsset',     'Digital collectible',         3),
  ('domainOrIntellectual',  'digitalAsset',     'Domain or intellectual property', 4),

  -- Section C of the product definition: the structured physical inventory.
  ('jewellery',             'physicalValuable', 'Jewellery',                   1),
  ('artwork',               'physicalValuable', 'Artwork',                     2),
  ('collectible',           'physicalValuable', 'Collectible',                 3),
  ('vehicle',               'physicalValuable', 'Vehicle',                     4),
  ('safeDepositBox',        'physicalValuable', 'Safe deposit box',            5),
  ('preciousMetal',         'physicalValuable', 'Precious metal',              6),

  ('customAsset',           'otherAsset',       'Other',                       1)
on conflict (subtype) do update set
  parent_category = excluded.parent_category,
  display_name    = excluded.display_name,
  sort_order      = excluded.sort_order;

-- =============================================================================================
-- 5 · estate_assets — the inventory itself
-- =============================================================================================
create table if not exists public.estate_assets (
  id                      uuid        primary key default gen_random_uuid(),
  estate_id               uuid        not null references public.estates(id) on delete cascade,
  created_by              uuid        not null references auth.users(id),

  -- Persist-both taxonomy, same discipline as documents: the fine subtype AND its coarse parent, so
  -- a client that has never heard of a new subtype can still group the row.
  category                text        not null references public.estate_asset_category(value),
  subtype                 text        not null references public.estate_asset_subtype(subtype),

  label                   text        not null,
  -- ★ THE SAME LADDER AS DOCUMENTS, ON PURPOSE. `document_grantable` is defined over exactly these
  -- five values, so an asset carrying a value from a DIFFERENT ladder could not be reasoned about by
  -- the ceiling the estate already has. One sensitivity vocabulary per estate, not two.
  -- (The catalog's NAME is document-flavoured; renaming it is a wider migration than this slice, and
  -- is ledgered rather than done here under cover of an inventory change.)
  sensitivity             text        not null default 'sealed' references public.document_sensitivity(value),

  owner_label             text,                     -- "Jointly held", "Held in trust" — free text
  country_code            text        check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  jurisdiction            text,                     -- state / province / canton
  institution_name        text,
  -- ★ A HINT, AND THE SCHEMA ENFORCES THAT IT CANNOT BE MORE. Capped at 12 characters so a full
  -- account number, IBAN or wallet address is UNSTORABLE rather than merely discouraged. A field
  -- that can hold a secret eventually holds one.
  reference_hint          text        check (reference_hint is null or length(reference_hint) <= 12),

  approximate_value_cents bigint      check (approximate_value_cents is null or approximate_value_cents >= 0),
  currency                text        not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  notes                   text,
  -- Who is named AT THE INSTITUTION (an IRA beneficiary, a policy nominee). INFORMATIONAL RECORD
  -- KEEPING — it confers no access in this product and grants nothing.
  beneficiary_note        text,

  verification_status     text        not null default 'unverified'
                            check (verification_status in ('unverified','ownerAsserted','documented','verified')),

  -- Soft deletion. NULL = live. The pair is set and cleared together by the archive/restore RPCs.
  archived_at             timestamptz,
  archived_by             uuid        references auth.users(id),

  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  constraint estate_assets_label_not_blank check (length(btrim(label)) > 0),
  constraint estate_assets_label_len       check (length(label) <= 200),
  constraint estate_assets_archived_pair   check ((archived_at is null) = (archived_by is null))
);
create index if not exists estate_assets_estate_idx on public.estate_assets (estate_id);
-- Partial index: the common read is "the live inventory", and archived rows drop out of it.
create index if not exists estate_assets_live_idx on public.estate_assets (estate_id, created_at desc)
  where archived_at is null;

alter table public.estate_assets enable row level security;

-- READ: estate OWNER ONLY, through the is_estate_owner DEFINER helper. An inline estate_memberships
-- subquery would FAIL here (authenticated holds no SELECT grant on it — the policy subquery runs as
-- the invoker), which is the same reason connections/normalized_assets use the helper.
--
-- ★ NO aal2 CLAUSE, PER THE RULING. This policy is the ONLY read path, and it admits the owner only.
drop policy if exists estate_assets_read_owner on public.estate_assets;
create policy estate_assets_read_owner on public.estate_assets
  for select to authenticated using (public.is_estate_owner(estate_id));

-- WRITES ARE DEFINER-RPC-ONLY — the documents posture (0030). No INSERT/UPDATE/DELETE grant exists,
-- so validation, the audit trail and the archive semantics cannot be bypassed by a direct PostgREST
-- write. The table keeps exactly ONE client grant: authenticated SELECT.
grant select on table public.estate_assets to authenticated;

-- =============================================================================================
-- 6 · estate_asset_documents — evidence attached to an asset
-- =============================================================================================
-- ★ THE JOIN CARRIES NO AUTHORITY OF ITS OWN. Linking a document to an asset does not widen who may
-- read either one: the document keeps `documents_read` (owner, or a covering grant) and the asset
-- keeps owner-only. A join row is a statement about organisation, never about access.
create table if not exists public.estate_asset_documents (
  asset_id  uuid        not null references public.estate_assets(id) on delete cascade,
  doc_id    uuid        not null references public.documents(id) on delete cascade,
  linked_by uuid        not null references auth.users(id),
  linked_at timestamptz not null default now(),
  primary key (asset_id, doc_id)
);
create index if not exists estate_asset_documents_doc_idx on public.estate_asset_documents (doc_id);

alter table public.estate_asset_documents enable row level security;

-- Readable exactly when the asset is readable. `estate_assets` is owner-only, so this resolves to the
-- owner — expressed as a dependency on the asset rather than a second copy of the ownership rule, so
-- the two cannot drift apart.
drop policy if exists estate_asset_documents_read on public.estate_asset_documents;
create policy estate_asset_documents_read on public.estate_asset_documents
  for select to authenticated using (
    exists (select 1 from public.estate_assets a where a.id = asset_id and public.is_estate_owner(a.estate_id))
  );
grant select on table public.estate_asset_documents to authenticated;
-- No write grant: link/unlink are DEFINER RPCs.

-- ★ ON DELETE CASCADE from `documents` is what keeps this table honest. A vault document is HARD
-- deleted (0039), so its join rows must go with it; leaving a dangling asset↔doc row would render an
-- attachment for a document that no longer exists.

-- =============================================================================================
-- 7 · vocabulary versioning — the new catalogs share the existing taxonomy_version counter
-- =============================================================================================
-- ★ ONE COUNTER, ONE CLIENT CACHE INVALIDATION. The client caches the asset vocabulary by
-- `vocabulary_version` exactly as it caches the document vocabulary. Giving the asset catalogs their
-- own counter would mean a client had to track two, and the one it forgot would serve a stale
-- vocabulary indefinitely. `bump_taxonomy_vocabulary_version` (0036) is reused verbatim.
drop trigger if exists estate_asset_category_taxonomy_bump on public.estate_asset_category;
create trigger estate_asset_category_taxonomy_bump
  after insert or update or delete on public.estate_asset_category
  for each statement execute function public.bump_taxonomy_vocabulary_version();

drop trigger if exists estate_asset_subtype_taxonomy_bump on public.estate_asset_subtype;
create trigger estate_asset_subtype_taxonomy_bump
  after insert or update or delete on public.estate_asset_subtype
  for each statement execute function public.bump_taxonomy_vocabulary_version();

-- ★ THE TRIGGERS ARE CREATED AFTER THE SEED, deliberately, matching 0036: attaching them first would
-- bump the version once per seed statement and hand every client a version number that describes
-- nothing. One bump on the next real change is the useful signal.

commit;

-- =============================================================================================
-- 8 · RPCs — APPLY db/functions/estate_asset_rpcs.sql IMMEDIATELY AFTER THIS FILE
-- =============================================================================================
-- The function bodies live in ONE place (db/functions/estate_asset_rpcs.sql) rather than being
-- duplicated here. Two copies of a SECURITY DEFINER body is a drift hazard with an authorization
-- gate inside it: the copy that gets patched is not necessarily the copy that is deployed.
--
-- `scripts/buildEstateAssetBundle.mjs` concatenates this file and that one into a single paste-ready
-- artifact, so the SQL editor still gets one paste.
