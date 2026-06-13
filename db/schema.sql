-- Payment feature schema. This is the SOURCE OF TRUTH the AI reviewer compares code against.
-- Apply to a Supabase Postgres project, e.g.:
--   psql "postgresql://USER:PASSWORD@HOST:5432/postgres?sslmode=require" -f db/schema.sql
-- All objects live in the public schema.

begin;

create table if not exists payment_methods (
    id             bigint generated always as identity primary key,
    user_id        bigint      not null,
    type           text        not null check (type in ('card', 'bank_transfer', 'wallet')),
    card_last_four char(4),
    expiry_month   smallint    check (expiry_month between 1 and 12),
    expiry_year    smallint,
    created_at     timestamptz not null default now()
);

-- payment_methods.user_id is indexed (looked up by user).
create index if not exists idx_payment_methods_user_id on payment_methods (user_id);

create table if not exists payments (
    id                bigint generated always as identity primary key,
    user_id           bigint      not null,
    payment_method_id bigint      not null references payment_methods (id),
    amount_cents      integer     not null check (amount_cents >= 0),
    currency          char(3)     not null default 'USD',
    -- status allowed values are constrained; code MUST use exactly one of these.
    status            text        not null default 'pending'
        check (status in ('pending', 'authorized', 'captured', 'failed', 'refunded')),
    -- note is intentionally narrow so over-length writes surface a truncation WARNING.
    note              varchar(50),
    created_at        timestamptz not null default now()
);

-- payments.user_id is indexed so the baseline code is clean.
-- NOTE: payments.status is intentionally NOT indexed; the WARNING demo filters on it.
create index if not exists idx_payments_user_id on payments (user_id);

create table if not exists refunds (
    id           bigint generated always as identity primary key,
    payment_id   bigint      not null references payments (id),
    amount_cents integer     not null check (amount_cents >= 0),
    reason       text,
    created_at   timestamptz not null default now()
);

commit;
