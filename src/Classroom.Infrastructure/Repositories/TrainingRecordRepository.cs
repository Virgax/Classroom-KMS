using System.Data;
using Classroom.Domain.Models;
using Classroom.Infrastructure.Database;
using Dapper;

namespace Classroom.Infrastructure.Repositories;

public sealed class TrainingRecordRepository(IDbConnectionFactory db)
{
    /// <summary>
    /// Expediente de entrenamiento. El SP autoriza: el propio empleado
    /// siempre puede verse; ver a otros exige report.trainingrecord.
    /// </summary>
    public async Task<TrainingRecord> TrainingRecord_GetForEmployee(
        int actorUserId, int? employeeId = null, CancellationToken ct = default)
    {
        const string Sp = "rpt.usp_TrainingRecord_GetForEmployee";

        var p = new DynamicParameters();
        p.Add("@ActorUserId", actorUserId, DbType.Int32);
        p.Add("@EmployeeId", employeeId, DbType.Int32);

        using var conn = await db.OpenAsync(ct);
        using var grid = await conn.QueryMultipleAsync(
            new CommandDefinition(Sp, p, commandType: CommandType.StoredProcedure, cancellationToken: ct));

        var employee = await grid.ReadSingleOrDefaultAsync<TrainingRecordHeader>();  // 1 identificacion
        _ = await grid.ReadAsync();                                                  // 2 posiciones (no v1)
        var certs = (await grid.ReadAsync<CertificationRow>()).ToList();             // 3 certificaciones
        var enrollments = (await grid.ReadAsync<EnrollmentRow>()).ToList();          // 4 inscripciones
        _ = await grid.ReadAsync();                                                  // 5 sesiones ILT
        _ = await grid.ReadAsync();                                                  // 6 practicas
        _ = await grid.ReadAsync();                                                  // 7 intentos de quiz
        _ = await grid.ReadAsync();                                                  // 8 documentos firmados
        var gaps = (await grid.ReadAsync<GapRow>()).ToList();                        // 9 brechas abiertas

        return new TrainingRecord(employee, certs, enrollments, gaps);
    }
}
