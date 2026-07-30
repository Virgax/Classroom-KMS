using System.Data;
using Classroom.Domain.Models;
using Classroom.Infrastructure.Database;
using Dapper;

namespace Classroom.Infrastructure.Repositories;

public sealed class EmployeeRepository(IDbConnectionFactory db)
{
    public async Task<PagedResult<EmployeeListItem>> List(
        int actorUserId,
        string? searchText = null,
        int? departmentId = null,
        bool? isActive = true,
        int pageNumber = 1,
        int pageSize = 50,
        string? sortBy = null,
        string sortDir = "ASC",
        CancellationToken ct = default)
    {
        const string Sp = "org.usp_Employee_List";

        var p = new DynamicParameters();
        p.Add("@ActorUserId", actorUserId, DbType.Int32);
        p.Add("@SearchText", searchText, DbType.String, size: 100);
        p.Add("@DepartmentId", departmentId, DbType.Int32);
        p.Add("@IsActive", isActive, DbType.Boolean);
        p.Add("@PageNumber", pageNumber, DbType.Int32);
        p.Add("@PageSize", pageSize, DbType.Int32);
        p.Add("@SortBy", sortBy, DbType.String, size: 50);
        p.Add("@SortDir", sortDir, DbType.AnsiStringFixedLength, size: 4);

        using var conn = await db.OpenAsync(ct);
        using var grid = await conn.QueryMultipleAsync(
            new CommandDefinition(Sp, p, commandType: CommandType.StoredProcedure, cancellationToken: ct));

        var items = (await grid.ReadAsync<EmployeeListItem>()).ToList();
        var total = await grid.ReadSingleAsync<int>();

        return new PagedResult<EmployeeListItem>(items, total, pageNumber, pageSize);
    }
}
