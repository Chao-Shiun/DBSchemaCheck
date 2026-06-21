# Demo Scenarios

`main` / `master` contains schema-safe sample code. To demo ERROR or WARNING, add one of the snippets below to a feature branch and open a PR.

Schema facts from `db/schema.sql`:

- `payment_methods.card_last_four` is the real card column, not `card_last4`.
- `payments.status` allows only `pending`, `authorized`, `captured`, `failed`, and `refunded`.
- `payments.note` is `varchar(50)`.
- `payments.user_id` is `bigint`.

## A. ERROR

Any of these should be classified as ERROR because they create runtime or security failures.

```csharp
// ERROR: references card_last4 but the schema column is card_last_four.
public async Task<string?> GetMaskedCardAsync(long paymentMethodId)
{
    const string sql = "select card_last4 from payment_methods where id = @paymentMethodId";
    await using var connection = CreateConnection();
    return await connection.ExecuteScalarAsync<string?>(sql, new { paymentMethodId });
}

// ERROR: writes status 'PAID' which is rejected by the CHECK constraint.
public async Task MarkPaidAsync(long paymentId)
{
    const string sql = "update payments set status = 'PAID' where id = @paymentId";
    await using var connection = CreateConnection();
    await connection.ExecuteAsync(sql, new { paymentId });
}

// ERROR: untrusted input is interpolated directly into SQL.
public async Task<IReadOnlyList<Payment>> SearchByRawUserInputAsync(string userInput)
{
    string sql = $"select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where user_id = {userInput}";
    await using var connection = CreateConnection();
    var rows = await connection.QueryAsync<Payment>(sql);
    return rows.ToList();
}
```

Expected result:

- GitHub: `schema-gate=failure`, Slack `FAILED`.
- Bitbucket: bot reviewer requests changes, pipeline fails, Slack `FAILED` if Slack is configured.

## B. WARNING

Warnings should be issues that are concrete but not immediate runtime failures.

```csharp
// WARNING: bare AddWithValue infers Int32 for a bigint column, which can create implicit casts and poor plans.
public async Task<long> CountPaymentsForUserWarningAsync(int userId)
{
    await using var connection = CreateConnection();
    await connection.OpenAsync();
    await using var cmd = connection.CreateCommand();
    cmd.CommandText = "select count(*) from payments where user_id = @userId";
    cmd.Parameters.AddWithValue("userId", userId);
    return (long)(await cmd.ExecuteScalarAsync())!;
}

// WARNING: note may exceed varchar(50), causing truncation or a database error depending on provider behavior.
public async Task AddLongNoteAsync(long paymentId, string longNote)
{
    const string sql = "update payments set note = @longNote where id = @paymentId";
    await using var connection = CreateConnection();
    await connection.ExecuteAsync(sql, new { paymentId, longNote });
}
```

Expected result:

- GitHub: `schema-gate=pending`, Slack `WARNING` with approve/reject buttons.
- Bitbucket: bot reviewer requests changes first; Slack approval approves the PR, while Slack reject declines the PR.

## C. PASS

No intentional schema-risk snippets should result in PASS:

- GitHub: `schema-gate=success`, Slack `SUCCESS`.
- Bitbucket: bot reviewer approves, Slack `SUCCESS` if Slack is configured.
