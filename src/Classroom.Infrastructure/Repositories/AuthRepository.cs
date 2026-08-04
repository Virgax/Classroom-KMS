using System.Data;
using Classroom.Domain.Models;
using Classroom.Infrastructure.Database;
using Dapper;

namespace Classroom.Infrastructure.Repositories;

public sealed class AuthRepository(IDbConnectionFactory db)
{
    /// <summary>Fase 1: obtener material de hash. Null si el usuario no tiene credencial.</summary>
    public async Task<PinMaterial?> User_AuthenticatePin_GetMaterial(
        string employeeCode, int? deviceId, string? ipAddress, CancellationToken ct = default)
    {
        const string Sp = "sec.usp_User_AuthenticatePin";

        var p = new DynamicParameters();
        p.Add("@EmployeeCode", employeeCode, DbType.String, size: 100);
        p.Add("@Phase", (byte)1, DbType.Byte);
        p.Add("@DeviceId", deviceId, DbType.Int32);
        p.Add("@IpAddress", ipAddress, DbType.String, size: 45);

        using var conn = await db.OpenAsync(ct);
        return await conn.QuerySingleOrDefaultAsync<PinMaterial>(
            new CommandDefinition(Sp, p, commandType: CommandType.StoredProcedure, cancellationToken: ct));
    }

    /// <summary>Fase 2: registrar resultado. Lanza SqlException 50101 si no coincide.</summary>
    public async Task<AuthenticatedUser> User_AuthenticatePin_RecordResult(
        string employeeCode, bool isMatch, int? deviceId, string? ipAddress, CancellationToken ct = default)
    {
        const string Sp = "sec.usp_User_AuthenticatePin";

        var p = new DynamicParameters();
        p.Add("@EmployeeCode", employeeCode, DbType.String, size: 100);
        p.Add("@Phase", (byte)2, DbType.Byte);
        p.Add("@IsMatch", isMatch, DbType.Boolean);
        p.Add("@DeviceId", deviceId, DbType.Int32);
        p.Add("@IpAddress", ipAddress, DbType.String, size: 45);

        using var conn = await db.OpenAsync(ct);
        return await conn.QuerySingleAsync<AuthenticatedUser>(
            new CommandDefinition(Sp, p, commandType: CommandType.StoredProcedure, cancellationToken: ct));
    }

    public async Task<Guid> Session_Create(
        int userId, byte sessionType, int? deviceId, string? ipAddress, string? userAgent,
        int ttlMinutes = 480, CancellationToken ct = default)
    {
        const string Sp = "sec.usp_Session_Create";

        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int32);
        p.Add("@SessionType", sessionType, DbType.Byte);
        p.Add("@DeviceId", deviceId, DbType.Int32);
        p.Add("@IpAddress", ipAddress, DbType.String, size: 45);
        p.Add("@UserAgent", userAgent, DbType.String, size: 400);
        p.Add("@TtlMinutes", ttlMinutes, DbType.Int32);
        p.Add("@SessionId", dbType: DbType.Guid, direction: ParameterDirection.Output);

        using var conn = await db.OpenAsync(ct);
        await conn.ExecuteAsync(
            new CommandDefinition(Sp, p, commandType: CommandType.StoredProcedure, cancellationToken: ct));
        return p.Get<Guid>("@SessionId");
    }

    public async Task User_SetPin(
        int actorUserId, int userId, byte[] pinHash, byte[] pinSalt,
        int iterations, string algorithm, bool mustChange, CancellationToken ct = default)
    {
        const string Sp = "sec.usp_User_SetPin";

        var p = new DynamicParameters();
        p.Add("@ActorUserId", actorUserId, DbType.Int32);
        p.Add("@UserId", userId, DbType.Int32);
        p.Add("@PinHash", pinHash, DbType.Binary, size: 64);
        p.Add("@PinSalt", pinSalt, DbType.Binary, size: 32);
        p.Add("@Iterations", iterations, DbType.Int32);
        p.Add("@Algorithm", algorithm, DbType.String, size: 40);
        p.Add("@MustChange", mustChange, DbType.Boolean);

        using var conn = await db.OpenAsync(ct);
        await conn.ExecuteAsync(
            new CommandDefinition(Sp, p, commandType: CommandType.StoredProcedure, cancellationToken: ct));
    }

    /// <summary>Usuario por codigo de empleado (login de piso). Null si no existe.</summary>
    public async Task<UserByEmployeeCode?> User_GetByEmployeeCode(string employeeCode, CancellationToken ct = default)
    {
        const string Sp = "sec.usp_User_GetByEmployeeCode";

        var p = new DynamicParameters();
        p.Add("@EmployeeCode", employeeCode, DbType.String, size: 30);

        using var conn = await db.OpenAsync(ct);
        return await conn.QuerySingleOrDefaultAsync<UserByEmployeeCode>(
            new CommandDefinition(Sp, p, commandType: CommandType.StoredProcedure, cancellationToken: ct));
    }

    /// <summary>
    /// Crea usuarios para empleados activos sin cuenta y devuelve los
    /// pendientes de PIN inicial (con semilla) y los que requieren PIN manual.
    /// </summary>
    public async Task<(int UsersCreated, IReadOnlyList<PendingCredential> Pending, IReadOnlyList<string> ManualPinNeeded)>
        User_ProvisionForEmployees(int actorUserId, CancellationToken ct = default)
    {
        const string Sp = "sec.usp_User_ProvisionForEmployees";

        var p = new DynamicParameters();
        p.Add("@ActorUserId", actorUserId, DbType.Int32);
        p.Add("@UsersCreated", dbType: DbType.Int32, direction: ParameterDirection.Output);

        using var conn = await db.OpenAsync(ct);
        using var grid = await conn.QueryMultipleAsync(
            new CommandDefinition(Sp, p, commandType: CommandType.StoredProcedure, cancellationToken: ct));

        var pending = (await grid.ReadAsync<PendingCredential>()).ToList();
        var manual = (await grid.ReadAsync<PendingCredential>()).Select(m => m.EmployeeCode).ToList();

        return (p.Get<int>("@UsersCreated"), pending, manual);
    }
}
