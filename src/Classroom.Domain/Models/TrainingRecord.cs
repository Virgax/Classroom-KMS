namespace Classroom.Domain.Models;

/// <summary>Resultset 1 de rpt.usp_TrainingRecord_GetForEmployee.</summary>
public sealed record TrainingRecordHeader
{
    public int EmployeeId { get; init; }
    public string EmployeeCode { get; init; } = string.Empty;
    public string FullName { get; init; } = string.Empty;
    public string? NationalIdMasked { get; init; }
    public DateTime? HireDateUtc { get; init; }
    public bool IsActive { get; init; }
    public string? SiteName { get; init; }
    public string? DepartmentName { get; init; }
    public string? AreaName { get; init; }
    public string? PositionCode { get; init; }
    public string? PositionName { get; init; }
    public string? SupervisorName { get; init; }
}

/// <summary>Resultset 3: certificaciones.</summary>
public sealed record CertificationRow
{
    public string CertificateNumber { get; init; } = string.Empty;
    public string CompetencyCode { get; init; } = string.Empty;
    public string CompetencyName { get; init; } = string.Empty;
    public byte LevelOrdinal { get; init; }
    public string LevelName { get; init; } = string.Empty;
    public byte Status { get; init; }   // 1=Valid 2=ExpiringSoon 3=Expired 4=RetrainingRequired 5=Revoked 6=Provisional
    public DateTime IssuedAtUtc { get; init; }
    public DateTime? ExpiresAtUtc { get; init; }
    public string? RegulatoryBasis { get; init; }
    public byte? Criticality { get; init; }
}

/// <summary>Resultset 4: inscripciones.</summary>
public sealed record EnrollmentRow
{
    public string CourseCode { get; init; } = string.Empty;
    public string CourseNameEs { get; init; } = string.Empty;
    public byte EnrollmentStatus { get; init; }  // 1=Assigned 2=InProgress 3=Completed 4=Expired 5=Withdrawn 6=Failed
    public DateTime? AssignedAtUtc { get; init; }
    public DateTime? DueAtUtc { get; init; }
    public DateTime? CompletedAtUtc { get; init; }
    public decimal? ScorePercent { get; init; }
    public bool? IsPassed { get; init; }
}

/// <summary>Resultset 9: brechas abiertas.</summary>
public sealed record GapRow
{
    public string RequirementCode { get; init; } = string.Empty;
    public string CompetencyCode { get; init; } = string.Empty;
    public string CompetencyName { get; init; } = string.Empty;
    public byte GapType { get; init; }   // 1=NeverCertified 2=Expired 3=ExpiringSoon 4=RetrainingRequired 5=InsufficientLevel 6=Revoked
    public byte Severity { get; init; }  // 1=Critical 2=Major 3=Minor
    public DateTime? ExpiresAtUtc { get; init; }
    public int? DaysUntilExpiry { get; init; }
    public bool HasActiveWaiver { get; init; }
}

public sealed record TrainingRecord(
    TrainingRecordHeader? Employee,
    IReadOnlyList<CertificationRow> Certifications,
    IReadOnlyList<EnrollmentRow> Enrollments,
    IReadOnlyList<GapRow> OpenGaps);
