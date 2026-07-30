using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Microsoft.IdentityModel.Tokens;

namespace Classroom.Api.Auth;

public sealed class JwtTokenService(IConfiguration config)
{
    public const string UserIdClaim = "kms:userid";
    public const string SessionClaim = "kms:session";

    private readonly string _signingKey = config["KMS_JWT_SIGNING_KEY"]
        ?? throw new InvalidOperationException("Falta KMS_JWT_SIGNING_KEY (minimo 32 bytes).");
    private readonly string _issuer = config["KMS_JWT_ISSUER"] ?? "classroom.airlink.do";
    private readonly string _audience = config["KMS_JWT_AUDIENCE"] ?? "classroom-api";

    public TokenValidationParameters ValidationParameters => new()
    {
        ValidIssuer = _issuer,
        ValidAudience = _audience,
        IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_signingKey)),
        ValidateIssuer = true,
        ValidateAudience = true,
        ValidateLifetime = true,
        ClockSkew = TimeSpan.FromMinutes(1),
    };

    public string Issue(int userId, Guid sessionId, string displayName, TimeSpan lifetime)
    {
        var token = new JwtSecurityToken(
            issuer: _issuer,
            audience: _audience,
            claims:
            [
                new Claim(UserIdClaim, userId.ToString()),
                new Claim(SessionClaim, sessionId.ToString()),
                new Claim(ClaimTypes.Name, displayName),
            ],
            expires: DateTime.UtcNow.Add(lifetime),
            signingCredentials: new SigningCredentials(
                new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_signingKey)),
                SecurityAlgorithms.HmacSha256));

        return new JwtSecurityTokenHandler().WriteToken(token);
    }
}
