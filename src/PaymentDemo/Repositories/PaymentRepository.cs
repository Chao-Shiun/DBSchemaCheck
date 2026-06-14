using Dapper;
using Npgsql;
using PaymentDemo.Models;

namespace PaymentDemo.Repositories;

// Data access for the payment feature. This is the clean baseline on master:
// every query is parameterized (no SQL injection), and every column / value
// reference matches db/schema.sql exactly. See demo/DEMO.md for the deliberate
// drift used to demonstrate the CI gate.
public sealed class PaymentRepository(string connectionString)
{
    private NpgsqlConnection CreateConnection() => new(connectionString);

    // Returns the saved payment methods for a user. card_last_four matches the schema column.
    public async Task<IReadOnlyList<PaymentMethod>> GetPaymentMethodsAsync(long userId)
    {
        const string sql = "select id, user_id, type, card_last_four, expiry_month, expiry_year, created_at from payment_methods where user_id = @userId";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<PaymentMethod>(sql, new { userId });
        return rows.ToList();
    }

    // Inserts a payment. status uses 'pending', one of the schema CHECK allowed values.
    public async Task<long> CreatePaymentAsync(long userId, long paymentMethodId, int amountCents, string currency, string note)
    {
        const string sql = "insert into payments (user_id, payment_method_id, amount_cents, currency, status, note) values (@userId, @paymentMethodId, @amountCents, @currency, 'pending', @note) returning id";
        await using var connection = CreateConnection();
        return await connection.ExecuteScalarAsync<long>(sql, new { userId, paymentMethodId, amountCents, currency, note });
    }

    // Lists payments for a user. Parameterized and filtered on the indexed payments.user_id column.
    public async Task<IReadOnlyList<Payment>> GetPaymentsByUserAsync(long userId)
    {
        const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where user_id = @userId order by created_at desc";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<Payment>(sql, new { userId });
        return rows.ToList();
    }

    // Returns the masked card digits. card_last_four matches the schema column.
    public async Task<string?> GetMaskedCardAsync(long paymentMethodId)
    {
        const string sql = "select card_last_four from payment_methods where id = @paymentMethodId";
        await using var connection = CreateConnection();
        return await connection.ExecuteScalarAsync<string?>(sql, new { paymentMethodId });
    }

    // Marks a payment as captured. 'captured' is one of the schema CHECK allowed values.
    public async Task MarkCapturedAsync(long paymentId)
    {
        const string sql = "update payments set status = 'captured' where id = @paymentId";
        await using var connection = CreateConnection();
        await connection.ExecuteAsync(sql, new { paymentId });
    }

    // Lists a user's payments. Parameterized (no injection); payments.user_id is indexed.
    public async Task<IReadOnlyList<Payment>> SearchByUserIdAsync(long userId)
    {
        const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where user_id = @userId";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<Payment>(sql, new { userId });
        return rows.ToList();
    }
}
