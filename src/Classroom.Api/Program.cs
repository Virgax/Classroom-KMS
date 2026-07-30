using System.Security.Claims;
using Classroom.Api.Auth;
using Classroom.Infrastructure.Database;
using Classroom.Infrastructure.Repositories;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);

// Connection string: SOLO por configuracion (env var KMS_DB_CONNECTIONSTRING
// o ConnectionStrings__ClassroomKms). Nunca hardcodeada.
var connectionString =
    builder.Configuration.GetConnectionString("ClassroomKms")
    ?? builder.Configuration["KMS_DB_CONNECTIONSTRING"]
    ?? throw new InvalidOperationException(
        "Falta la cadena de conexion (ConnectionStrings__ClassroomKms o KMS_DB_CONNECTIONSTRING).");

builder.Services.AddSingleton<IDbConnectionFactory>(new SqlConnectionFactory(connectionString));
builder.Services.AddSingleton<EmployeeRepository>();
builder.Services.AddSingleton<HealthRepository>();

// Autenticacion.
// Produccion: OIDC contra Microsoft Entra ID (pendiente: TenantId/ClientId).
// Desarrollo: header X-Dev-UserId, solo si KMS_DEV_AUTH=1 y Development.
var devAuth = builder.Environment.IsDevelopment()
              && builder.Configuration["KMS_DEV_AUTH"] == "1";
if (devAuth)
{
    builder.Services
        .AddAuthentication(DevHeaderAuthHandler.SchemeName)
        .AddScheme<AuthenticationSchemeOptions, DevHeaderAuthHandler>(
            DevHeaderAuthHandler.SchemeName, null);
}
else
{
    // TODO Fase 1: Microsoft.Identity.Web con Entra ID.
    builder.Services.AddAuthentication();
}
builder.Services.AddAuthorization();

var app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();

// @ActorUserId SIEMPRE sale del principal autenticado, jamas del request.
static int ActorUserId(ClaimsPrincipal user) =>
    int.TryParse(user.FindFirstValue(DevHeaderAuthHandler.UserIdClaim), out var id)
        ? id
        : throw new UnauthorizedAccessException("Principal sin identidad de usuario.");

app.MapGet("/health", async (HealthRepository repo, CancellationToken ct) =>
{
    var status = await repo.GetStatus(ct);
    return Results.Ok(status);
});

app.MapGet("/api/employees", async (
    ClaimsPrincipal user,
    EmployeeRepository repo,
    CancellationToken ct,
    string? search,
    int page = 1,
    int pageSize = 50) =>
{
    try
    {
        var result = await repo.List(
            ActorUserId(user), searchText: search,
            pageNumber: page, pageSize: pageSize, ct: ct);

        // Contrato del API: PublicId (GUID), nunca el EmployeeId (INT).
        return Results.Ok(new
        {
            items = result.Items.Select(e => new
            {
                id = e.PublicId,
                e.EmployeeCode,
                e.FullName,
                e.Email,
                e.HireDateUtc,
                e.IsActive,
                e.DepartmentName,
                e.AreaName,
            }),
            total = result.TotalCount,
            page = result.PageNumber,
            pageSize = result.PageSize,
        });
    }
    catch (SqlException ex) when (ex.Number == 50002)
    {
        return Results.Forbid();
    }
}).RequireAuthorization();

app.Run();
