using System.Data;

namespace Classroom.Infrastructure.Database;

public interface IDbConnectionFactory
{
    Task<IDbConnection> OpenAsync(CancellationToken ct = default);
}
