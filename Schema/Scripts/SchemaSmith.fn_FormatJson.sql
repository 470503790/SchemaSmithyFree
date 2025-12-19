IF OBJECT_ID('SchemaSmith.fn_FormatJson', 'IF') IS NOT NULL
  DROP FUNCTION SchemaSmith.fn_FormatJson
GO

CREATE FUNCTION SchemaSmith.fn_FormatJson(@Json NVARCHAR(MAX), @Level INT) 
  RETURNS @r_Result TABLE ([LineNo] INT IDENTITY(1,1), [Line] NVARCHAR(MAX))
AS 
BEGIN
  INSERT @r_Result ([Line])
    VALUES (ISNULL(@Json, ''))

  RETURN
END
