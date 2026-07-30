using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace Classroom.Api.Auth;

/// <summary>
/// SOLO DESARROLLO. Autentica con el header X-Dev-UserId (UserId de sec.User).
/// Se registra unicamente cuando KMS_DEV_AUTH=1 y el entorno es Development.
/// En produccion el esquema es OIDC contra Microsoft Entra ID y este handler
/// no existe en el pipeline.
/// </summary>
public sealed class DevHeaderAuthHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string SchemeName = "DevHeader";
    public const string UserIdClaim = "kms:userid";

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue("X-Dev-UserId", out var raw) ||
            !int.TryParse(raw.ToString(), out var userId) || userId <= 0)
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        var identity = new ClaimsIdentity(
            [new Claim(UserIdClaim, userId.ToString())], SchemeName);
        var ticket = new AuthenticationTicket(new ClaimsPrincipal(identity), SchemeName);
        return Task.FromResult(AuthenticateResult.Success(ticket));
    }
}
