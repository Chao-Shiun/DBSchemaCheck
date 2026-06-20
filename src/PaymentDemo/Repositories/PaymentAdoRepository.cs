using Npgsql;
using NpgsqlTypes;
using PaymentDemo.Models;

namespace PaymentDemo.Repositories;

// Demo repository that uses raw ADO.NET (Npgsql) with schema-safe patterns.
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
        cmd.Parameters.Add("status", NpgsqlDbType.Text).Value = status;
        return (long)(await cmd.ExecuteScalarAsync())!;
    }

    // Counts payments for a user with a parameter type that matches payments.user_id.
    public async Task<long> CountPaymentsForUserAsync(long userId)
    {
        await using var connection = CreateConnection();
        await connection.OpenAsync();
        await using var cmd = connection.CreateCommand();
        cmd.CommandText = "select count(*) from payments where user_id = @userId";
        cmd.Parameters.Add("userId", NpgsqlDbType.Bigint).Value = userId;
        return (long)(await cmd.ExecuteScalarAsync())!;
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

    // Inserts a moderate batch in one database round trip.
    public async Task InsertPaymentsAsync(IReadOnlyList<(long userId, long methodId, int amountCents)> rows)
    {
        if (rows.Count == 0)
        {
            return;
        }

        await using var connection = CreateConnection();
        await connection.OpenAsync();
        await using var batch = new NpgsqlBatch(connection);
        foreach (var row in rows)
        {
            var command = new NpgsqlBatchCommand("insert into payments (user_id, payment_method_id, amount_cents, status) values (@u, @m, @a, 'pending')");
            command.Parameters.Add("u", NpgsqlDbType.Bigint).Value = row.userId;
            command.Parameters.Add("m", NpgsqlDbType.Bigint).Value = row.methodId;
            command.Parameters.Add("a", NpgsqlDbType.Integer).Value = row.amountCents;
            batch.BatchCommands.Add(command);
        }

        await batch.ExecuteNonQueryAsync();
    }

    // Uses a single typed array parameter instead of expanding IN-list parameters.
    public async Task<IReadOnlyList<Payment>> GetByStatusesAsync(string[] statuses)
    {
        if (statuses.Length == 0)
        {
            return [];
        }

        const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where status = any(@statuses)";
        await using var connection = CreateConnection();
        await connection.OpenAsync();
        await using var cmd = connection.CreateCommand();
        cmd.CommandText = sql;
        cmd.Parameters.Add("statuses", NpgsqlDbType.Array | NpgsqlDbType.Text).Value = statuses;
        await using var reader = await cmd.ExecuteReaderAsync();

        var payments = new List<Payment>();
        while (await reader.ReadAsync())
        {
            payments.Add(ReadPayment(reader));
        }

        return payments;
    }

    private static Payment ReadPayment(NpgsqlDataReader reader)
    {
        return new Payment(
            reader.GetInt64(0),
            reader.GetInt64(1),
            reader.GetInt64(2),
            reader.GetInt32(3),
            reader.GetString(4),
            reader.GetString(5),
            reader.IsDBNull(6) ? null : reader.GetString(6),
            reader.GetDateTime(7));
    }
}
