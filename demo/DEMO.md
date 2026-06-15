# Demo 操作手冊：如何觸發三種閘門路徑

`master` 上的 `PaymentRepository.cs` 是**乾淨的基準**（參數化、欄位/狀態值都符合 schema），
所以直接對它開 PR 會走 **PASS**。要示範 **ERROR** 與 **WARNING**，請在功能分支上把下列方法
加進 `src/PaymentDemo/Repositories/PaymentRepository.cs` 的類別內，再對 `master` 開 PR。

> 對照基準：`db/schema.sql`
> - `payment_methods.card_last_four`（不是 `card_last4`）
> - `payments.status` 僅允許 `pending / authorized / captured / failed / refunded`
> - `payments.status` **沒有索引**；`payments.note` 為 `varchar(50)`

---

## A. 觸發 ERROR（會被阻擋、CI 失敗、Slack 發 FAILED）

把以下三個方法加入類別。任一個都會讓本次審查歸類為 ERROR：

```csharp
// ERROR: references card_last4 but the schema column is card_last_four -> runtime error
public async Task<string?> GetMaskedCardAsync(long paymentMethodId)
{
    const string sql = "select card_last4 from payment_methods where id = @paymentMethodId";
    await using var connection = CreateConnection();
    return await connection.ExecuteScalarAsync<string?>(sql, new { paymentMethodId });
}

// ERROR: writes status 'PAID' which is not allowed by the CHECK constraint -> runtime error
public async Task MarkPaidAsync(long paymentId)
{
    const string sql = "update payments set status = 'PAID' where id = @paymentId";
    await using var connection = CreateConnection();
    await connection.ExecuteAsync(sql, new { paymentId });
}

// ERROR (SQL injection): untrusted input interpolated directly into the SQL string
public async Task<IReadOnlyList<Payment>> SearchByRawUserInputAsync(string userInput)
{
    string sql = $"select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where user_id = {userInput}";
    await using var connection = CreateConnection();
    var rows = await connection.QueryAsync<Payment>(sql);
    return rows.ToList();
}
```

預期：`schema-gate` = failure、CI 失敗、Slack 收到 **FAILED** 並逐項列出問題與修正建議。

---

## B. 觸發 WARNING（不阻擋、Slack 發 WARNING + 放行/拒絕按鈕）

把以下兩個方法加入類別（不要同時加入 A 的方法，否則會被 ERROR 蓋過）：

```csharp
// WARNING: filters payments.status which has no index -> performance
public async Task<IReadOnlyList<Payment>> GetPaymentsByStatusAsync(string status)
{
    const string sql = "select id, user_id, payment_method_id, amount_cents, currency, status, note, created_at from payments where status = @status";
    await using var connection = CreateConnection();
    var rows = await connection.QueryAsync<Payment>(sql, new { status });
    return rows.ToList();
}

// WARNING: note may exceed varchar(50) -> data truncation / length mismatch
public async Task AddLongNoteAsync(long paymentId, string longNote)
{
    const string sql = "update payments set note = @longNote where id = @paymentId";
    await using var connection = CreateConnection();
    await connection.ExecuteAsync(sql, new { paymentId, longNote });
}
```

預期：`schema-gate` = pending（PR 被卡住）、Slack 收到 **WARNING** 與兩顆按鈕。
- 按「放行」→ Edge Function 送出 `repository_dispatch`，`resume` job 將 `schema-gate` 設為 success 並跑佈署 placeholder，Slack 訊息更新為已放行。
- 按「拒絕」→ Edge Function 送出 `repository_dispatch`，`resume` job 將 `schema-gate` 設為 failure，Slack 訊息更新為已取消。

---

## C. 觸發 PASS（綠燈通過、Slack 發 SUCCESS）

不加入任何上述方法，或把 A/B 的問題都改正後開 PR：`schema-gate` = success、Slack 收到 **SUCCESS**。
