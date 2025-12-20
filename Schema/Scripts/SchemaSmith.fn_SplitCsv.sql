IF OBJECT_ID('SchemaSmith.fn_SplitCsv', 'IF') IS NOT NULL
  DROP FUNCTION SchemaSmith.fn_SplitCsv
GO

CREATE FUNCTION SchemaSmith.fn_SplitCsv(@Csv NVARCHAR(MAX))
RETURNS @r_Result TABLE ([Value] NVARCHAR(MAX))
AS
BEGIN
  DECLARE @Xml XML
  DECLARE @XmlString NVARCHAR(MAX)

  IF @Csv IS NULL OR LTRIM(RTRIM(@Csv)) = ''
    RETURN

  SET @XmlString = CAST('<i>' AS NVARCHAR(MAX)) +
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
                   CAST('</i>' AS NVARCHAR(MAX))

  SET @Xml = CAST(@XmlString AS XML)

  INSERT @r_Result ([Value])
    SELECT LTRIM(RTRIM(x.Item.value('.', 'NVARCHAR(MAX)')))
      FROM @Xml.nodes('/i') x(Item)
      WHERE LTRIM(RTRIM(x.Item.value('.', 'NVARCHAR(MAX)'))) <> ''

  RETURN
END
