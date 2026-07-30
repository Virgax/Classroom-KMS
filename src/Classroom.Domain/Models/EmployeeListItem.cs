namespace Classroom.Domain.Models;

/// <summary>Fila del listado de empleados (org.usp_Employee_List).</summary>
public sealed record EmployeeListItem
{
    // EmployeeId (INT) se mapea internamente pero NUNCA se expone en el API.
    public int EmployeeId { get; init; }
    public Guid PublicId { get; init; }
    public string EmployeeCode { get; init; } = string.Empty;
    public string FullName { get; init; } = string.Empty;
    public string? Email { get; init; }
    public DateTime? HireDateUtc { get; init; }
    public bool IsActive { get; init; }
    public string? DepartmentName { get; init; }
    public string? AreaName { get; init; }
}
