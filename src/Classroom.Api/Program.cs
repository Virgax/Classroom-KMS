using System.Security.Claims;
using Classroom.Api.Auth;
using Classroom.Infrastructure.Auth;
using Classroom.Infrastructure.Database;
using Classroom.Infrastructure.Repositories;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
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
builder.Services.AddSingleton<AuthRepository>();
builder.Services.AddSingleton<TrainingRecordRepository>();
builder.Services.AddSingleton<JwtTokenService>();

// CORS: el frontend (Vite) corre en otro puerto en desarrollo.
var corsOrigins = (builder.Configuration["KMS_CORS_ORIGINS"] ?? "http://localhost:5173")
    .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
builder.Services.AddCors(o => o.AddDefaultPolicy(p =>
    p.WithOrigins(corsOrigins).AllowAnyHeader().AllowAnyMethod()));

/* =====================================================================
   Autenticacion universal: codigo de empleado + PIN -> JWT propio.
   No todo el personal tiene correo/Entra: el login de piso es el metodo
   por defecto para todo el mundo. Entra ID se integrara como metodo
   adicional para quien tenga cuenta (AuthMethod 1 o 3).
   En Development, el header X-Dev-UserId sigue disponible (KMS_DEV_AUTH=1).
   ===================================================================== */
var jwt = new JwtTokenService(builder.Configuration);
var devAuth = builder.Environment.IsDevelopment()
              && builder.Configuration["KMS_DEV_AUTH"] == "1";

var auth = builder.Services.AddAuthentication("Smart");
auth.AddJwtBearer(options => options.TokenValidationParameters = jwt.ValidationParameters);
auth.AddPolicyScheme("Smart", "JWT o DevHeader", options =>
{
    options.ForwardDefaultSelector = ctx =>
        devAuth && ctx.Request.Headers.ContainsKey("X-Dev-UserId")
            ? DevHeaderAuthHandler.SchemeName
            : JwtBearerDefaults.AuthenticationScheme;
});
if (devAuth)
{
    auth.AddScheme<AuthenticationSchemeOptions, DevHeaderAuthHandler>(
        DevHeaderAuthHandler.SchemeName, null);
}
builder.Services.AddAuthorization();

var app = builder.Build();
app.UseCors();
app.UseAuthentication();
app.UseAuthorization();

// @ActorUserId SIEMPRE sale del principal autenticado, jamas del request.
static int ActorUserId(ClaimsPrincipal user) =>
    int.TryParse(user.FindFirstValue(JwtTokenService.UserIdClaim), out var id)
        ? id
        : throw new UnauthorizedAccessException("Principal sin identidad de usuario.");

static bool IsValidPin(string? pin) =>
    !string.IsNullOrEmpty(pin) && pin.Length is >= 4 and <= 8 && pin.All(char.IsAsciiDigit);

app.MapGet("/health", async (HealthRepository repo, CancellationToken ct) =>
    Results.Ok(await repo.GetStatus(ct)));

/* ---------------------------------------------------------------------
   POST /api/auth/login   { employeeCode, pin }
   PIN = ultimos 4 de la cedula.

   Con KMS_PA_LOGIN_URL configurada, la validacion la hace el flow de
   Power Automate (SP_Hub_ValidateLogin) — que ademas trae la foto del
   empleado, que se guarda en org.EmployeePhoto. Si el flow esta caido,
   cae al PIN local (PBKDF2) para que el piso no se detenga.
   Sin la URL, el PIN local es el unico metodo.
   --------------------------------------------------------------------- */
var paLoginUrl = builder.Configuration["KMS_PA_LOGIN_URL"];
var paLogin = string.IsNullOrWhiteSpace(paLoginUrl)
    ? null
    : new PowerAutomateLoginClient(new HttpClient { Timeout = TimeSpan.FromSeconds(20) }, paLoginUrl);

app.MapPost("/api/auth/login", async (
    LoginRequest req, AuthRepository repo, EmployeeRepository employees,
    JwtTokenService tokens, HttpContext http, CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(req.EmployeeCode) || !IsValidPin(req.Pin))
        return Results.Json(new { error = "Codigo o PIN incorrecto." }, statusCode: 401);

    var code = req.EmployeeCode.Trim().ToUpperInvariant();
    var ip = http.Connection.RemoteIpAddress?.ToString();
    var userAgent = http.Request.Headers.UserAgent.ToString();

    async Task<IResult> LocalPinLogin()
    {
        try
        {
            var material = await repo.User_AuthenticatePin_GetMaterial(code, null, ip, ct);
            var isMatch = material is not null
                          && PinHasher.Verify(req.Pin!, material.PinSalt, material.Iterations, material.PinHash);

            // La fase 2 SIEMPRE se registra: exitos y fallos quedan en
            // sec.LoginAttempt y el contador de bloqueo vive en el SP.
            var user = await repo.User_AuthenticatePin_RecordResult(code, isMatch, null, ip, ct);

            var sessionId = await repo.Session_Create(user.UserId, sessionType: 1, null, ip, userAgent, ct: ct);
            var token = tokens.Issue(user.UserId, sessionId, user.DisplayName, TimeSpan.FromHours(8));

            return Results.Ok(new
            {
                token,
                displayName = user.DisplayName,
                preferredLocale = user.PreferredLocale,
                mustChangePin = user.MustChangePin,
            });
        }
        catch (SqlException ex) when (ex.Number is 50101)
        {
            return Results.Json(new { error = "Codigo o PIN incorrecto." }, statusCode: 401);
        }
        catch (SqlException ex) when (ex.Number is 50102)
        {
            return Results.Json(new { error = "Cuenta bloqueada temporalmente. Contacte a su supervisor." }, statusCode: 423);
        }
    }

    if (paLogin is null) return await LocalPinLogin();

    PowerAutomateLoginClient.PaLoginResult pa;
    try
    {
        pa = await paLogin.Validate(code, req.Pin!, ct);
    }
    catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or InvalidOperationException)
    {
        // Flow caido o inalcanzable: el piso sigue con el PIN local.
        return await LocalPinLogin();
    }

    if (!pa.IsValid)
        return Results.Json(new { error = "Codigo o PIN incorrecto." }, statusCode: 401);

    var kmsUser = await repo.User_GetByEmployeeCode(code, ct);
    if (kmsUser is null || !kmsUser.IsActive)
        return Results.Json(
            new { error = "Empleado validado pero sin usuario en el KMS. Corra el aprovisionamiento." },
            statusCode: 403);

    var paSessionId = await repo.Session_Create(kmsUser.UserId, sessionType: 1, null, ip, userAgent, ct: ct);
    var paToken = tokens.Issue(kmsUser.UserId, paSessionId, kmsUser.DisplayName, TimeSpan.FromHours(8));

    // La foto del hub se refresca en cada login. Si falla, el login sigue.
    var hasPhoto = false;
    if (!string.IsNullOrEmpty(pa.PhotoB64) && kmsUser.EmployeeId is int empId)
    {
        try
        {
            var bytes = Convert.FromBase64String(pa.PhotoB64);
            if (bytes.Length > 0)
            {
                await employees.EmployeePhoto_Upsert(kmsUser.UserId, empId, bytes, ct: ct);
                hasPhoto = true;
            }
        }
        catch (FormatException) { /* foto invalida: se ignora */ }
        catch (SqlException) { /* no bloquear el login por la foto */ }
    }

    return Results.Ok(new
    {
        token = paToken,
        displayName = kmsUser.DisplayName,
        preferredLocale = kmsUser.PreferredLocale,
        mustChangePin = false,
        hasPhoto,
    });
});

/* ---------------------------------------------------------------------
   GET /api/me/photo — foto del empleado autenticado (base64).
   --------------------------------------------------------------------- */
app.MapGet("/api/me/photo", async (
    ClaimsPrincipal user, EmployeeRepository employees, CancellationToken ct) =>
{
    var photo = await employees.EmployeePhoto_Get(ActorUserId(user), null, ct);
    return photo is null
        ? Results.NotFound(new { error = "Sin foto registrada." })
        : Results.Ok(new { contentType = photo.ContentType, photoB64 = Convert.ToBase64String(photo.PhotoBytes) });
}).RequireAuthorization();

/* ---------------------------------------------------------------------
   POST /api/auth/change-pin   { employeeCode, currentPin, newPin }
   --------------------------------------------------------------------- */
app.MapPost("/api/auth/change-pin", async (
    ChangePinRequest req, ClaimsPrincipal principal, AuthRepository repo,
    HttpContext http, CancellationToken ct) =>
{
    if (!IsValidPin(req.NewPin))
        return Results.BadRequest(new { error = "El PIN nuevo debe ser de 4 a 8 digitos." });

    var actorId = ActorUserId(principal);
    var ip = http.Connection.RemoteIpAddress?.ToString();

    try
    {
        var material = await repo.User_AuthenticatePin_GetMaterial(req.EmployeeCode.Trim(), null, ip, ct);
        var isMatch = material is not null && material.UserId == actorId
                      && PinHasher.Verify(req.CurrentPin ?? "", material.PinSalt, material.Iterations, material.PinHash);
        await repo.User_AuthenticatePin_RecordResult(req.EmployeeCode.Trim(), isMatch, null, ip, ct);

        var (hash, salt) = PinHasher.Hash(req.NewPin!);
        await repo.User_SetPin(actorId, actorId, hash, salt,
            PinHasher.Iterations, PinHasher.Algorithm, mustChange: false, ct);

        return Results.Ok(new { changed = true });
    }
    catch (SqlException ex) when (ex.Number is 50101 or 50102)
    {
        return Results.Json(new { error = "PIN actual incorrecto." }, statusCode: 401);
    }
}).RequireAuthorization();

/* ---------------------------------------------------------------------
   POST /api/admin/users/provision
   Crea usuarios para todos los empleados activos y les asigna el PIN
   inicial (ultimos 4 de cedula). El SP valida el permiso user.manage.
   --------------------------------------------------------------------- */
app.MapPost("/api/admin/users/provision", async (
    ClaimsPrincipal principal, AuthRepository repo, IConfiguration config, CancellationToken ct) =>
{
    var actorId = ActorUserId(principal);
    var mustChange = config["KMS_PIN_MUST_CHANGE"] == "1";

    try
    {
        var (created, pending, manual) = await repo.User_ProvisionForEmployees(actorId, ct);

        var credentialsSet = 0;
        foreach (var u in pending)
        {
            var (hash, salt) = PinHasher.Hash(u.PinSeed);
            await repo.User_SetPin(actorId, u.UserId, hash, salt,
                PinHasher.Iterations, PinHasher.Algorithm, mustChange, ct);
            credentialsSet++;
        }

        return Results.Ok(new { usersCreated = created, credentialsSet, manualPinNeeded = manual });
    }
    catch (SqlException ex) when (ex.Number == 50002)
    {
        return Results.Forbid();
    }
}).RequireAuthorization();

/* ---------------------------------------------------------------------
   GET /api/me/record — Mi expediente de entrenamiento.
   El SP autoriza: uno mismo siempre; otros exigen report.trainingrecord.
   --------------------------------------------------------------------- */
app.MapGet("/api/me/record", async (
    ClaimsPrincipal user, TrainingRecordRepository repo, CancellationToken ct) =>
{
    try
    {
        var record = await repo.TrainingRecord_GetForEmployee(ActorUserId(user), null, ct);
        return record.Employee is null
            ? Results.NotFound(new { error = "El usuario no tiene expediente de empleado." })
            : Results.Ok(record);
    }
    catch (SqlException ex) when (ex.Number == 50002)
    {
        return Results.Forbid();
    }
}).RequireAuthorization();

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

public sealed record LoginRequest(string EmployeeCode, string? Pin);
public sealed record ChangePinRequest(string EmployeeCode, string? CurrentPin, string? NewPin);
