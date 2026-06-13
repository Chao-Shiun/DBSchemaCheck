-- Optional seed data for local exploration. Run against a fresh demo database.

insert into payment_methods (user_id, type, card_last_four, expiry_month, expiry_year)
values (1, 'card', '4242', 12, 2030);

insert into payments (user_id, payment_method_id, amount_cents, currency, status, note)
values (1, 1, 1999, 'USD', 'captured', 'first order');
