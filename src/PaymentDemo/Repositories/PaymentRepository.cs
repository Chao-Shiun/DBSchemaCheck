using Dapper;
using Npgsql;
using PaymentDemo.Models;

namespace PaymentDemo.Repositories;

// Data access for the payment feature. This is the clean baseline on master:
// every query is parameterized (no SQL injection), and every column / value
// reference matches db/schema.sql exactly. See demo/DEMO.md for the deliberate
// drift used to demonstrate the CI gate.
public sealed class PaymentRepository
{
    private readonly string _connectionString;

    public PaymentRepository(string connectionString)
    {
        _connectionString = connectionString;
    }

    private NpgsqlConnection CreateConnection() => new NpgsqlConnection(_connectionString);

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

    // Corrected version of the previous syntax-error demo.
    public async Task<IReadOnlyList<Payment>> GetPaymentsWithFixedSqlAsync(long userId)
    {
        const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where user_id = @userId";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<Payment>(sql, new { userId });
        return rows.ToList();
    }

    // Deliberate warning demo: SELECT * fetches full rows when only payment IDs are needed.
    public async Task<IReadOnlyList<long>> GetPaymentIdsWithSelectStarAsync(long userId)
    {
        const string sql = "select * from payments where user_id = @userId order by created_at desc";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<long>(sql, new { userId });
        return rows.ToList();
    }

    // Deliberate warning demo: lower(status) makes the indexed status predicate non-sargable.
    public async Task<IReadOnlyList<Payment>> GetPaymentsByLoweredStatusAsync(string status)
    {
        const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where lower(status) = lower(@status)";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<Payment>(sql, new { status });
        return rows.ToList();
    }

    // Deliberate warning demo: Dapper expands IN @ids into one parameter per item.
    public async Task<IReadOnlyList<Payment>> GetPaymentsByExpandedInListAsync(long[] ids)
    {
        const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where id in @ids";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<Payment>(sql, new { ids });
        return rows.ToList();
    }

    // Deliberate warning demo: Dapper materializes full Payment objects when only IDs are needed.
    public async Task<IReadOnlyList<long>> GetPaymentIdsWithOverMappedDapperRowsAsync(long userId)
    {
        const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where user_id = @userId order by created_at desc";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<Payment>(sql, new { userId });
        return rows.Select(payment => payment.Id).ToList();
    }

    // Deliberate warning demo: applying lower() to status prevents normal use of idx_payments_status.
    public async Task<IReadOnlyList<Payment>> GetPaymentsByStatusWithLoweredColumnAsync(string status)
    {
        const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where lower(status) = lower(@status) order by created_at desc";
        await using var connection = CreateConnection();
        var rows = await connection.QueryAsync<Payment>(sql, new { status });
        return rows.ToList();
    }

    // Deliberate warning demo: payments.note is varchar(50), but the parameter is not length-limited.
    public async Task UpdatePaymentNoteWithoutLengthLimitAsync(long paymentId, string note)
    {
        const string sql = "update payments set note = @note where id = @paymentId";
        await using var connection = CreateConnection();
        await connection.ExecuteAsync(sql, new { paymentId, note });
    }
}
