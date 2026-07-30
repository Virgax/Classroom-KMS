namespace Classroom.Domain.Models;

/// <summary>Primer resultset de ops.usp_Health_GetStatus.</summary>
public sealed record HealthStatus
{
    public int NotificationsPending { get; init; }
    public int NotificationsDeadLetter { get; init; }
    public int OpenIntegrationErrors { get; init; }
    public DateTime? LastEmployeeSyncUtc { get; init; }
    public int ErrorsLast24h { get; init; }
    public int FailedJobsLast24h { get; init; }
    public int OpenCriticalGaps { get; init; }
    public int AttemptsInProgress { get; init; }
}
