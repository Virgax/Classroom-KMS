namespace Classroom.Domain.Models;

/// <summary>Fase 1 de sec.usp_User_AuthenticatePin: material de hash.</summary>
public sealed record PinMaterial
{
    public byte[] PinHash { get; init; } = [];
    public byte[] PinSalt { get; init; } = [];
    public int Iterations { get; init; }
    public string Algorithm { get; init; } = string.Empty;
    public int UserId { get; init; }
}

/// <summary>Fase 2 de sec.usp_User_AuthenticatePin: usuario autenticado.</summary>
public sealed record AuthenticatedUser
{
    public int UserId { get; init; }
    public Guid PublicId { get; init; }
    public int? EmployeeId { get; init; }
    public string DisplayName { get; init; } = string.Empty;
    public string PreferredLocale { get; init; } = "es-DO";
    public bool MustChangePin { get; init; }
    public bool IsPinExpired { get; init; }
}

/// <summary>Usuario pendiente de PIN inicial (usp_User_ProvisionForEmployees).</summary>
public sealed record PendingCredential
{
    public int UserId { get; init; }
    public string EmployeeCode { get; init; } = string.Empty;
    public string DisplayName { get; init; } = string.Empty;
    public string PinSeed { get; init; } = string.Empty;
}

public sealed record ProvisionResult(
    int UsersCreated,
    int CredentialsSet,
    IReadOnlyList<string> ManualPinNeeded);

/// <summary>sec.usp_User_GetByEmployeeCode.</summary>
public sealed record UserByEmployeeCode
{
    public int UserId { get; init; }
    public Guid PublicId { get; init; }
    public int? EmployeeId { get; init; }
    public string UserName { get; init; } = string.Empty;
    public string DisplayName { get; init; } = string.Empty;
    public string PreferredLocale { get; init; } = "es-DO";
    public byte AuthMethod { get; init; }
    public bool IsActive { get; init; }
}

/// <summary>org.usp_EmployeePhoto_Get.</summary>
public sealed record EmployeePhoto
{
    public string ContentType { get; init; } = "image/jpeg";
    public byte[] PhotoBytes { get; init; } = [];
    public DateTime UpdatedAtUtc { get; init; }
}
