using System;
using System.Collections.Generic;
using System.Data;
using System.IO;
using System.Linq;
using log4net;
using Microsoft.Extensions.Configuration;
using Schema.DataAccess;
using Schema.Isolators;
using Schema.Utility;

namespace DataTongs;

public class DataTongs
{
    private readonly ILog _progressLog = LogFactory.GetLogger("ProgressLog");

    private IDbConnection GetConnection(string targetDb)
    {
        var config = FactoryContainer.ResolveOrCreate<IConfigurationRoot>();

        var connectionString = ConnectionString.Build(config["Source:Server"], targetDb, config["Source:User"], config["Source:Password"]);

        var connection = SqlConnectionFactory.GetFromFactory().GetSqlConnection(connectionString);

        connection.Open();
        return connection;
    }

    public void CastData()
    {
        var config = FactoryContainer.ResolveOrCreate<IConfigurationRoot>();

        var disableTriggers = config["ShouldCast:DisableTriggers"]?.ToLower() == "true";
        var mergeUpdate = config["ShouldCast:MergeUpdate"]?.ToLower() != "false";
        var mergeDelete = config["ShouldCast:MergeDelete"]?.ToLower() != "false";
        var outputPath = Path.Combine(config["OutputPath"] ?? ".");
        DirectoryWrapper.GetFromFactory().CreateDirectory(outputPath);

        var sourceDb = config["Source:Database"]!;
        if (string.IsNullOrEmpty(sourceDb)) throw new Exception("需要指定源数据库（Source database）");

        var tables = config.GetSection("Tables")
            .AsEnumerable()
            .Where(x => x.Value != null)
            .Select(x => new KeyValuePair<string, string>(x.Key.Replace("Tables:", ""), x.Value!));
        var tableFilters = config.GetSection("TableFilters")
            .AsEnumerable()
            .Where(x => !x.Key.Equals("TableFilters"))
            .ToDictionary(t => t.Key.Replace("TableFilters:", ""), t => t.Value);

        _progressLog.Info("Starting DataTongs...（开始 DataTongs）");
        using var sourceConnection = GetConnection(sourceDb);
        var cmd = sourceConnection.CreateCommand();
        foreach (var table in tables)
        {
            _progressLog.Info($"  Casting data for: {table.Key}（生成数据）");
            var parts = table.Key.Split('.').Select(p => p.Trim()).ToArray();
            var tableSchema = parts.Length == 2 ? parts[0] : "dbo";
            var tableName = parts.Length == 2 ? parts[1] : parts[0];
            var matchColumns = string.Join(" AND ", table.Value.Split(',').Select(c => $"Source.[{c.Trim().Trim(']', '[')}] = Target.[{c.Trim().Trim(']', '[')}]"));
            var orderColumns = string.Join(",", table.Value.Split(',').Select(c => $"[{c.Trim().Trim(']', '[')}]"));

            var selectColumns = GetSelectColumns(cmd, tableSchema, tableName);
            tableFilters.TryGetValue(table.Key, out var filter);
            var tableData = GetTableData(cmd, selectColumns, tableSchema, tableName, orderColumns, filter);

            var mergeSQL = BuildMergeSql(cmd, tableSchema, tableName, tableData, matchColumns, disableTriggers, mergeUpdate, mergeDelete, filter);

            FileWrapper.GetFromFactory().WriteAllText(Path.Combine(outputPath, $"Populate {tableSchema}.{tableName}.sql"), mergeSQL);
        }
        sourceConnection.Close();
        _progressLog.Info("DataTongs completed successfully.（DataTongs 成功完成）");
    }

    private static string BuildMergeSql(IDbCommand cmd, string tableSchema, string tableName, string? tableData, string matchColumns, bool disableTriggers, bool mergeUpdate, bool mergeDelete, string? filter)
    {
        var fromXmlSelectColumns = GetFromXmlSelectColumns(cmd, tableSchema, tableName);
        var insertColumns = GetInsertColumns(cmd, tableSchema, tableName);
        var identityInsert = CheckIdentityInsertRequired(cmd, tableSchema, tableName);

        // Build the core MERGE statement
        var mergeSQL = $@"DECLARE @v_xml_data NVARCHAR(MAX) = ";
        
        // Split large XML data into chunks to avoid string literal size limitations
        // SQL Server has a limit on string literals (around 4000-8000 chars depending on context)
        var escapedTableData = tableData?.Replace("'", "''") ?? "";
        const int chunkSize = 4000;
        
        if (escapedTableData.Length <= chunkSize)
        {
            mergeSQL += $"N'{escapedTableData}';\r\n";
        }
        else
        {
            // Split into chunks and concatenate
            // Note: Using Substring is acceptable here as this is a one-time SQL generation operation
            var chunks = new List<string>();
            for (int i = 0; i < escapedTableData.Length; i += chunkSize)
            {
                var length = Math.Min(chunkSize, escapedTableData.Length - i);
                chunks.Add($"N'{escapedTableData.Substring(i, length)}'");
            }
            mergeSQL += string.Join(" +\r\n       ", chunks) + ";\r\n";
        }

        mergeSQL += $@"DECLARE @v_xml XML = CAST(@v_xml_data AS XML);

{(disableTriggers ? $"ALTER TABLE [{tableSchema}].[{tableName}] DISABLE TRIGGER ALL;" : "")}
{(identityInsert ? $"SET IDENTITY_INSERT [{tableSchema}].[{tableName}] ON;" : "")} 
MERGE INTO [{tableSchema}].[{tableName}] AS Target
USING (
  SELECT {fromXmlSelectColumns}
    FROM @v_xml.nodes('/rows/row') AS x([Row])
) AS Source
ON {matchColumns}
";
        if (mergeUpdate)
        {
            var updateColumns = GetUpdateColumns(cmd, tableSchema, tableName);
            var updateCompare = string.Join(" AND ",
                updateColumns!.Split(',').Select(c => c.StartsWith("G[")
                    ? $"NOT (Target.{c.Substring(1)}.ToString() = Source.{c.Substring(1)}.ToString() OR (Target.{c.Substring(1)} IS NULL AND Source.{c.Substring(1)} IS NULL))"
                    : c.StartsWith("X[") || c.StartsWith("N[")
                        ? $"NOT (CAST(Target.{c.Substring(1)} AS NVARCHAR(MAX)) = CAST(Source.{c.Substring(1)} AS NVARCHAR(MAX)) OR (Target.{c.Substring(1)} IS NULL AND Source.{c.Substring(1)} IS NULL))"
                        : c.StartsWith("T[")
                            ? $"NOT (CAST(Target.{c.Substring(1)} AS VARCHAR(MAX)) = CAST(Source.{c.Substring(1)} AS VARCHAR(MAX)) OR (Target.{c.Substring(1)} IS NULL AND Source.{c.Substring(1)} IS NULL))"
                            : c.StartsWith("I[")
                                ? $"NOT (CAST(Target.{c.Substring(1)} AS VARBINARY(MAX)) = CAST(Source.{c.Substring(1)} AS VARBINARY(MAX)) OR (Target.{c.Substring(1)} IS NULL AND Source.{c.Substring(1)} IS NULL))"
                                : $"NOT (Target.{c} = Source.{c} OR (Target.{c} IS NULL AND Source.{c} IS NULL))"));

            mergeSQL += $@"

WHEN MATCHED AND ({updateCompare}) THEN
  UPDATE SET
{string.Join(",\r\n", updateColumns.Split(',').Select(c => $"        {c.Replace("G[", "[").Replace("X[", "[").Replace("N[", "[").Replace("T[", "[").Replace("I[", "[")} = Source.{c.Replace("G[", "[").Replace("X[", "[").Replace("N[", "[").Replace("T[", "[").Replace("I[", "[")}"))}
";
        }

        mergeSQL += $@"

WHEN NOT MATCHED THEN
  INSERT (
{insertColumns}
  ) VALUES (
{insertColumns!.Replace("[", "Source.[")}  
  )
";

        if (mergeDelete)
        {
            mergeSQL += $@"
 
 WHEN NOT MATCHED BY SOURCE{(string.IsNullOrWhiteSpace(filter) ? "" : $" AND ({filter})")} THEN
   DELETE 
 ";
        }

        mergeSQL += $";\r\n{(identityInsert ? $"SET IDENTITY_INSERT [{tableSchema}].[{tableName}] OFF;\r\n" : "")}{(disableTriggers ? $"ALTER TABLE [{tableSchema}].[{tableName}] ENABLE TRIGGER ALL;\r\n" : "")}";
        return mergeSQL;
    }

    private static string? GetTableData(IDbCommand cmd, string? selectColumns, string tableSchema, string tableName, string orderColumns, string? filter)
    {
        cmd.CommandText = $@"
SELECT CAST((
SELECT {selectColumns} 
  FROM [{tableSchema}].[{tableName}] WITH (NOLOCK) 
  {(string.IsNullOrWhiteSpace(filter) ? "" : $"WHERE {filter}")}
  ORDER BY {orderColumns}
  FOR XML PATH('row'), ROOT('rows'), TYPE) AS NVARCHAR(MAX))
";
        return cmd.ExecuteScalar()?.ToString();
    }

    private static bool CheckIdentityInsertRequired(IDbCommand cmd, string tableSchema, string tableName)
    {
        cmd.CommandText = $@"
SELECT CAST(CASE WHEN EXISTS (SELECT * FROM sys.identity_columns WITH (NOLOCK) WHERE [object_id] = OBJECT_ID('{tableSchema}.{tableName}'))
                 THEN 1 ELSE 0 END AS BIT)
";
        return cmd.ExecuteScalar() as bool? ?? false;
    }

    private static string? GetInsertColumns(IDbCommand cmd, string tableSchema, string tableName)
    {
        cmd.CommandText = $@"
SELECT STUFF((SELECT ',' + CHAR(13) + CHAR(10) + '        [' + c.COLUMN_NAME + ']'
                FROM INFORMATION_SCHEMA.COLUMNS c
                JOIN sys.columns sc WITH (NOLOCK) ON sc.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME) AND sc.[name] = C.COLUMN_NAME
                LEFT JOIN sys.identity_columns ident WITH (NOLOCK) ON ident.[Name] = COLUMN_NAME
                                                            AND ident.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME)
                LEFT JOIN sys.computed_columns cc WITH (NOLOCK) ON cc.[name] = c.COLUMN_NAME
                                                           AND cc.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME)
                WHERE c.TABLE_SCHEMA = '{tableSchema}' AND c.TABLE_NAME = '{tableName}'
                  AND cc.[name] IS NULL
                  AND sc.is_rowguidcol = 0
                ORDER BY c.COLUMN_NAME
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, '')
";
        return cmd.ExecuteScalar()?.ToString();
    }

    private static string? GetUpdateColumns(IDbCommand cmd, string tableSchema, string tableName)
    {
        cmd.CommandText = $@"
SELECT STUFF((SELECT ',' + CASE WHEN c.DATA_TYPE = 'GEOGRAPHY' THEN 'G' 
                                 WHEN c.DATA_TYPE = 'XML' THEN 'X' 
                                 WHEN c.DATA_TYPE = 'NTEXT' THEN 'N' 
                                 WHEN c.DATA_TYPE = 'TEXT' THEN 'T' 
                                 WHEN c.DATA_TYPE = 'IMAGE' THEN 'I' 
                                 ELSE '' END + 
                            '[' + c.COLUMN_NAME + ']'
                FROM INFORMATION_SCHEMA.COLUMNS c
                JOIN sys.columns sc WITH (NOLOCK) ON sc.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME) AND sc.[name] = C.COLUMN_NAME
                LEFT JOIN sys.identity_columns ident WITH (NOLOCK) ON ident.[Name] = COLUMN_NAME
                                                                AND ident.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME)
                LEFT JOIN sys.computed_columns cc WITH (NOLOCK) ON cc.[name] = c.COLUMN_NAME
                                                           AND cc.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME)
                WHERE c.TABLE_SCHEMA = '{tableSchema}' AND c.TABLE_NAME = '{tableName}'
                  AND ident.[Name] IS NULL
                  AND cc.[name] IS NULL
                  AND sc.is_rowguidcol = 0
                ORDER BY c.COLUMN_NAME
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '')
";
        return cmd.ExecuteScalar()?.ToString();
    }

    private static string? GetFromXmlSelectColumns(IDbCommand cmd, string tableSchema, string tableName)
    {
        cmd.CommandText = $@"
SELECT STUFF((SELECT ', ' + CASE WHEN c.DATA_TYPE = 'GEOGRAPHY' 
                                 THEN 'geography::STGeomFromText(x.[Row].value(''(' + c.COLUMN_NAME + '/text())[1]'', ''NVARCHAR(MAX)''), x.[Row].value(''(' + c.COLUMN_NAME + '_STSrid/text())[1]'', ''INT'')) AS [' + c.COLUMN_NAME + ']'
                                 ELSE 'x.[Row].value(''(' + c.COLUMN_NAME + '/text())[1]'', ''' +
                                      REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(UPPER(st.USER_TYPE), 'HIERARCHYID', 'NVARCHAR(4000)'), 'GEOGRAPHY', 'NVARCHAR(4000)'), 'NTEXT', 'NVARCHAR(MAX)'), 'TEXT', 'VARCHAR(MAX)'), 'IMAGE', 'VARBINARY(MAX)') + 
                                      CASE WHEN st.USER_TYPE LIKE '%CHAR' OR st.USER_TYPE LIKE '%BINARY'
                                           THEN '(' + CASE WHEN CHARACTER_MAXIMUM_LENGTH = -1 THEN 'MAX' ELSE CONVERT(NVARCHAR(20), CHARACTER_MAXIMUM_LENGTH) END + ')'
                                           WHEN st.USER_TYPE IN ('NUMERIC', 'DECIMAL')
                                           THEN  '(' + CONVERT(NVARCHAR(20), NUMERIC_PRECISION) + ', ' + CONVERT(NVARCHAR(20), NUMERIC_SCALE) + ')'
                                           WHEN st.USER_TYPE = 'DATETIME2'
                                           THEN  '(' + CONVERT(NVARCHAR(20), DATETIME_PRECISION) + ')'
                                           WHEN st.USER_TYPE = 'XML' AND sc.xml_collection_id <> 0
                                           THEN  '([' + SCHEMA_NAME(xc.[schema_id]) + '].[' + xc.[name] + '])'
                                           ELSE '' END +
                                      ''') AS [' + c.COLUMN_NAME + ']' END
                FROM INFORMATION_SCHEMA.COLUMNS c
                JOIN sys.columns sc WITH (NOLOCK) ON sc.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME) AND sc.[name] = C.COLUMN_NAME
                JOIN (SELECT CASE WHEN SCHEMA_NAME(st.[schema_id]) IN ('sys', 'dbo')
                                  THEN '' ELSE SCHEMA_NAME(st.[schema_id]) + '.' END + st.[name] AS USER_TYPE, st.user_type_id
                        FROM sys.types st WITH (NOLOCK)) st ON st.user_type_id = sc.user_type_id
                LEFT JOIN sys.xml_schema_collections xc WITH (NOLOCK) ON xc.xml_collection_id = sc.xml_collection_id
                LEFT JOIN sys.computed_columns cc WITH (NOLOCK) ON cc.[name] = c.COLUMN_NAME
                                                               AND cc.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME)
                WHERE c.TABLE_SCHEMA = '{tableSchema}' AND c.TABLE_NAME = '{tableName}'
                  AND cc.[name] IS NULL
                  AND sc.is_rowguidcol = 0
                ORDER BY c.COLUMN_NAME
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
";
        return cmd.ExecuteScalar()?.ToString();
    }

    private static string? GetSelectColumns(IDbCommand cmd, string tableSchema, string tableName)
    {
        cmd.CommandText = $@"
SELECT STUFF((SELECT ',' + CASE WHEN c.DATA_TYPE = 'GEOGRAPHY' 
                                 THEN '[' + c.COLUMN_NAME + '].ToString() AS [' + c.COLUMN_NAME + '], [' + c.COLUMN_NAME + '].STSrid AS [' + c.COLUMN_NAME + '_STSrid]'
                                 ELSE '[' + c.COLUMN_NAME + ']' END
                FROM INFORMATION_SCHEMA.COLUMNS c
                JOIN sys.columns sc WITH (NOLOCK) ON sc.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME) AND sc.[name] = C.COLUMN_NAME
                LEFT JOIN sys.computed_columns cc WITH (NOLOCK) ON cc.[name] = c.COLUMN_NAME
                                                           AND cc.[object_id] = OBJECT_ID(C.TABLE_SCHEMA + '.' + C.TABLE_NAME)
                WHERE c.TABLE_SCHEMA = '{tableSchema}' AND c.TABLE_NAME = '{tableName}'
                  AND cc.[name] IS NULL
	              AND sc.is_rowguidcol = 0
                ORDER BY c.COLUMN_NAME
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '')
";
        return cmd.ExecuteScalar()?.ToString();
    }
}
