IF OBJECT_ID('SchemaSmith.fn_SplitCsv', 'IF') IS NOT NULL
  DROP FUNCTION SchemaSmith.fn_SplitCsv
GO

CREATE FUNCTION SchemaSmith.fn_SplitCsv(@Csv NVARCHAR(MAX))
RETURNS @r_Result TABLE ([Value] NVARCHAR(MAX))
AS
BEGIN
  DECLARE @Xml XML

  IF @Csv IS NULL OR LTRIM(RTRIM(@Csv)) = ''
    RETURN

  SET @Xml = CAST('<i>' +
                  REPLACE(
                    REPLACE(
                      REPLACE(
                        REPLACE(@Csv, '&', '&amp;'),
                        '<', '&lt;'
                      ),
                      '>', '&gt;'
                    ),
                    ',', '</i><i>'
                  ) +
                  '</i>' AS XML)

  INSERT @r_Result ([Value])
    SELECT LTRIM(RTRIM(x.Item.value('.', 'NVARCHAR(MAX)')))
      FROM @Xml.nodes('/i') x(Item)
      WHERE LTRIM(RTRIM(x.Item.value('.', 'NVARCHAR(MAX)'))) <> ''

  RETURN
END
