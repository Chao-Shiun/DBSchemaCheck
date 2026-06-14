using Dapper;
using Npgsql;
using PaymentDemo.Models;

namespace PaymentDemo.Repositories;

// Demo repository that mixes raw ADO.NET (Npgsql) and Dapper. It INTENTIONALLY contains
// bad patterns so the CI schema reviewer can be verified against the ADO.NET + Dapper rules.
public sealed class PaymentAdoRepository(string connectionString)
{
    private NpgsqlConnection CreateConnection() => new(connectionString);

    // Counts payments by status. Parameterized, so no SQL injection.
    public async Task<long> CountPaymentsByStatusAsync(string status)
    {
        await using var connection = CreateConnection();
        await connection.OpenAsync();
        await using var cmd = connection.CreateCommand();
        cmd.CommandText = "select count(*) from payments where status = @status";
        cmd.Parameters.AddWithValue("status", status);
        return (long)(await cmd.ExecuteScalarAsync())!;
    }

    // WARNING: bare AddWithValue infers Int32 for the bigint indexed column user_id, producing an
    // implicit cast that can skip the index.
    public async Task<int> CountPaymentsForUserAsync(int userId)
    {
        await using var connection = CreateConnection();
        await connection.OpenAsync();
        await using var cmd = connection.CreateCommand();
        cmd.CommandText = "select count(*) from payments where user_id = @userId";
        cmd.Parameters.AddWithValue("userId", userId);
        return Convert.ToInt32(await cmd.ExecuteScalarAsync());
    }

    // Reads the first card_last_four. Guards the empty result set and the nullable column.
    public async Task<string?> GetFirstCardLastFourAsync()
    {
        await using var connection = CreateConnection();
        await connection.OpenAsync();
        await using var cmd = connection.CreateCommand();
        cmd.CommandText = "select card_last_four from payment_methods order by id limit 1";
        await using var reader = await cmd.ExecuteReaderAsync();
        if (!await reader.ReadAsync() || reader.IsDBNull(0))
        {
            return null;
        }
        return reader.GetString(0);
    }

    // WARNING: inserts one row per round trip in a loop instead of a bulk path (COPY / unnest / batch).
    public async Task InsertPaymentsAsync(IReadOnlyList<(long userId, long methodId, int amountCents)> rows)
    {
        await using var connection = CreateConnection();
        await connection.OpenAsync();
        foreach (var row in rows)
        {
            await using var cmd = connection.CreateCommand();
            cmd.CommandText = "insert into payments (user_id, payment_method_id, amount_cents, status) values (@u, @m, @a, 'pending')";
            cmd.Parameters.AddWithValue("u", row.userId);
            cmd.Parameters.AddWithValue("m", row.methodId);
            cmd.Parameters.AddWithValue("a", row.amountCents);
            await cmd.ExecuteNonQueryAsync();
        }
    }

    // WARNING (Dapper): IN @statuses is expanded into IN (@s1,@s2,...), churning the plan cache.
    public async Task<IReadOnlyList<Payment>> GetByStatusesAsync(string[] statuses)
    {
        const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where status in @statuses";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<Payment>(sql, new { statuses });
        return rows.ToList();
    }
}
