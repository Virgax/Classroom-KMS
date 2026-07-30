using System.Security.Cryptography;

namespace Classroom.Infrastructure.Auth;

/// <summary>
/// PBKDF2-HMACSHA256 para PINes de piso. El hash y el salt se calculan
/// aqui: T-SQL nunca ve el PIN en claro (ver sec.UserCredential).
/// </summary>
public static class PinHasher
{
    public const int Iterations = 210_000;
    public const string Algorithm = "PBKDF2-HMACSHA256";
    private const int SaltBytes = 32;
    private const int HashBytes = 64;

    public static (byte[] Hash, byte[] Salt) Hash(string pin)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        var hash = Rfc2898DeriveBytes.Pbkdf2(pin, salt, Iterations, HashAlgorithmName.SHA256, HashBytes);
        return (hash, salt);
    }

    public static bool Verify(string pin, byte[] salt, int iterations, byte[] expectedHash)
    {
        var computed = Rfc2898DeriveBytes.Pbkdf2(pin, salt, iterations, HashAlgorithmName.SHA256, expectedHash.Length);
        return CryptographicOperations.FixedTimeEquals(computed, expectedHash);
    }
}
