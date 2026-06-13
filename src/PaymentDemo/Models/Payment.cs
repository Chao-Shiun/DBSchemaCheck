namespace PaymentDemo.Models;

// Immutable view of a row in the payments table.
public sealed record Payment(long Id, long UserId, long PaymentMethodId, int AmountCents, string Currency, string Status, string? Note, DateTime CreatedAt);

// Immutable view of a row in the payment_methods table.
public sealed record PaymentMethod(long Id, long UserId, string Type, string? CardLastFour, short? ExpiryMonth, short? ExpiryYear, DateTime CreatedAt);
