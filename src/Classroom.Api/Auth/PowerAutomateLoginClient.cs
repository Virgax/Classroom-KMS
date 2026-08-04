using System.Text;
using System.Text.Json;

namespace Classroom.Api.Auth;

/// <summary>
/// Cliente del flow de Power Automate que valida el login contra el hub
/// de SPN (SP_Hub_ValidateLogin) y devuelve datos + foto del empleado.
///
/// SIEMPRE se llama desde el API: la URL del flow contiene la firma
/// (sig=...) y es una credencial. Nunca debe llegar al navegador.
/// Config: KMS_PA_LOGIN_URL (secret store / variable de entorno).
/// </summary>
public sealed class PowerAutomateLoginClient(HttpClient http, string flowUrl)
{
    public sealed record PaLoginResult(
        bool IsValid,
        string EmployeeCode,
        string EmployeeName,
        string? EmployeeEmail,
        string? PositionName,
        string? DepartmentName,
        int ReportLevel,
        string? PhotoB64);

    public async Task<PaLoginResult> Validate(string employeeCode, string lastFour, CancellationToken ct)
    {
        using var body = new StringContent(
            JsonSerializer.Serialize(new { employeeCode, lastFour }),
            Encoding.UTF8, "application/json");

        using var response = await http.PostAsync(flowUrl, body, ct);
        response.EnsureSuccessStatusCode();

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        var root = doc.RootElement;

        // El flow serializa todo como strings ("isValid": "true").
        static string Str(JsonElement e, string name) =>
            e.TryGetProperty(name, out var v) ? v.GetString() ?? "" : "";

        return new PaLoginResult(
            IsValid: string.Equals(Str(root, "isValid"), "true", StringComparison.OrdinalIgnoreCase),
            EmployeeCode: Str(root, "employeeCode"),
            EmployeeName: Str(root, "employeeName"),
            EmployeeEmail: Str(root, "employeeEmail"),
            PositionName: Str(root, "positionName"),
            DepartmentName: Str(root, "departmentName"),
            ReportLevel: int.TryParse(Str(root, "reportLevel"), out var rl) ? rl : 0,
            PhotoB64: Str(root, "photoB64"));
    }
}
