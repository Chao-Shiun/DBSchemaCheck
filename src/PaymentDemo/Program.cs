using PaymentDemo.Repositories;

// Minimal entrypoint demonstrating the payment repository against Supabase Postgres.
// The connection string is read from the SUPABASE_DB_CONNECTION environment variable.
var connectionString = Environment.GetEnvironmentVariable("SUPABASE_DB_CONNECTION");
if (string.IsNullOrWhiteSpace(connectionString))
{
    Console.WriteLine("Set SUPABASE_DB_CONNECTION to run against a real database.");
    return;
}

var repository = new PaymentRepository(connectionString);

var methods = await repository.GetPaymentMethodsAsync(1);
Console.WriteLine($"User 1 has {methods.Count} payment method(s).");

var payments = await repository.GetPaymentsByUserAsync(1);
Console.WriteLine($"User 1 has {payments.Count} payment(s).");
