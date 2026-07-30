using System.Data;
using Classroom.Domain.Models;
using Classroom.Infrastructure.Database;
using Dapper;

namespace Classroom.Infrastructure.Repositories;

public sealed class HealthRepository(IDbConnectionFactory db)
{
    public async Task<HealthStatus> GetStatus(CancellationToken ct = default)
    {
        const string Sp = "ops.usp_Health_GetStatus";

        using var conn = await db.OpenAsync(ct);
        using var grid = await conn.QueryMultipleAsync(
            new CommandDefinition(Sp, commandType: CommandType.StoredProcedure, cancellationToken: ct));

        return await grid.ReadSingleAsync<HealthStatus>();
    }
}
