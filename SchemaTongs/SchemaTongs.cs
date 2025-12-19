using log4net;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.SqlServer.Management.Common;
using Microsoft.SqlServer.Management.Smo;
using Newtonsoft.Json;
using Schema.DataAccess;
using Schema.Isolators;
using Schema.Utility;
using System;
using System.Data;
using System.IO;
using System.Linq;
using System.Xml.Linq;
using System.Xml.Serialization;

namespace SchemaTongs;

public class SchemaTongs
{
    private readonly ILog _progressLog = LogFactory.GetLogger("ProgressLog");
    private string _productPath = "";
    private string _templatePath = "";
    private readonly ScriptingOptions _options = new()
    {
        SchemaQualify = true,
        NoCollation = true,
        WithDependencies = false,
        ExtendedProperties = true,
        AllowSystemObjects = false,
        Permissions = false,
        ScriptForCreateOrAlter = true,
        ScriptForCreateDrop = false,
        IncludeIfNotExists = true
    };
    private bool _includeTables;
    private bool _includeSchemas;
    private bool _includeUserDefinedTypes;
    private bool _includeUserDefinedFunctions;
    private bool _includeViews;
    private bool _includeStoredProcedures;
    private bool _includeTableTriggers;
    private bool _includeFullTextCatalogs;
    private bool _includeFullTextStopLists;
    private bool _includeDDLTriggers;
    private bool _includeXmlSchemaCollections;
    private bool _scriptDynamicDependencyRemovalForFunctions;
    private string[] _objectsToCast = [];

    private IDbConnection GetConnection(string targetDb)
    {
        var config = FactoryContainer.ResolveOrCreate<IConfigurationRoot>();

        var connectionString = ConnectionString.Build(config["Source:Server"], targetDb, config["Source:User"], config["Source:Password"]);

        var connection = SqlConnectionFactory.GetFromFactory().GetSqlConnection(connectionString);

        connection.Open();
        return connection;
    }

    public void CastTemplate()
    {
        var config = FactoryContainer.ResolveOrCreate<IConfigurationRoot>();
        var targetDb = config["Source:Database"]!;
        if (string.IsNullOrEmpty(targetDb)) throw new Exception("需要指定源数据库（Source database）");
        _productPath = Path.Combine(config["Product:Path"] ?? ".");

        _includeTables = config["ShouldCast:Tables"]?.ToLower() != "false";
        _includeSchemas = config["ShouldCast:Schemas"]?.ToLower() != "false";
        _includeUserDefinedTypes = config["ShouldCast:UserDefinedTypes"]?.ToLower() != "false";
        _includeUserDefinedFunctions = config["ShouldCast:UserDefinedFunctions"]?.ToLower() != "false";
        _includeViews = config["ShouldCast:Views"]?.ToLower() != "false";
        _includeStoredProcedures = config["ShouldCast:StoredProcedures"]?.ToLower() != "false";
        _includeTableTriggers = config["ShouldCast:TableTriggers"]?.ToLower() != "false";
        _includeFullTextCatalogs = config["ShouldCast:Catalogs"]?.ToLower() != "false";
        _includeFullTextStopLists = config["ShouldCast:StopLists"]?.ToLower() != "false";
        _includeDDLTriggers = config["ShouldCast:DDLTriggers"]?.ToLower() != "false";
        _includeXmlSchemaCollections = config["ShouldCast:XMLSchemaCollections"]?.ToLower() != "false";
        _scriptDynamicDependencyRemovalForFunctions = config["ShouldCast:ScriptDynamicDependencyRemovalForFunctions"]?.ToLower() == "true";
        _objectsToCast = (config["ShouldCast:ObjectList"]?.ToLower() ?? "").Split(new []{ ',', ';' }, StringSplitOptions.RemoveEmptyEntries);

        RepositoryHelper.UpdateOrInitRepository(_productPath, config["Product:Name"], config["Template:Name"], targetDb);
        _templatePath = RepositoryHelper.UpdateOrInitTemplate(_productPath, config["Template:Name"], targetDb);
        CastDatabaseObjects(targetDb);
    }

    private void CastDatabaseObjects(string targetDb)
    {
        using var connection = GetConnection(targetDb);
        using var command = connection.CreateCommand();

        _progressLog.Info("Kindling The Forge（点燃熔炉）");
        ForgeKindler.KindleTheForge(command);

        if (_includeTables) ExtractTableDefinitions(command, targetDb);

        var serverConnection = new ServerConnection((SqlConnection)connection);
        var server = new Server(serverConnection);
        var sourceDb = server.Databases[targetDb];
        if (_includeSchemas) ScriptSchemas(sourceDb);
        if (_includeUserDefinedTypes) ScriptUserDefinedTypes(sourceDb);
        if (_includeUserDefinedFunctions) ScriptUserDefinedFunctions(sourceDb);
        if (_includeViews) ScriptViews(sourceDb);
        if (_includeStoredProcedures) ScriptStoredProcedures(sourceDb);
        if (_includeTableTriggers) ScriptTableTriggers(sourceDb);
        if (_includeFullTextCatalogs) ScriptFullTextCatalogs(sourceDb);
        if (_includeFullTextStopLists) ScriptFullTextStopLists(sourceDb);
        if (_includeDDLTriggers) ScriptDDLTriggers(sourceDb);
        if (_includeXmlSchemaCollections) ScriptXmlSchemaCollections(sourceDb);
        _progressLog.Info("");
        _progressLog.Info("Casting Completed Successfully（生成完成）");
    }

    private void ScriptSchemas(Database sourceDb)
    {
        _progressLog.Info("Casting Schema Scripts（生成架构脚本）");
        sourceDb.PrefetchObjects(typeof(Microsoft.SqlServer.Management.Smo.Schema), _options);
        var castPath = Path.Combine(_templatePath, "Schemas");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (Microsoft.SqlServer.Management.Smo.Schema schema in sourceDb.Schemas)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(schema.Name.ToLower())) continue;
            if (schema.IsSystemObject || schema.Name.Contains(@"\") || schema.Name.EqualsIgnoringCase("SchemaSmith")) continue;

            var fileName = Path.Combine(castPath, $"{schema.Name}.sql");
            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, string.Join("\r\n", schema.Script(_options).Cast<string>()));
        }
    }

    private void ScriptUserDefinedTypes(Database sourceDb)
    {
        _progressLog.Info("Casting User Defined Types（生成用户自定义类型）");
        sourceDb.PrefetchObjects(typeof(UserDefinedDataType), _options);
        sourceDb.PrefetchObjects(typeof(UserDefinedTableType), _options);
        var castPath = Path.Combine(_templatePath, "DataTypes");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (UserDefinedDataType type in sourceDb.UserDefinedDataTypes)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(type.Name.ToLower()) && !_objectsToCast.Contains($"{type.Schema}.{type.Name}".ToLower())) continue;
            
            var fileName = Path.Combine(castPath, $"{type.Schema}.{type.Name}.sql");
            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, string.Join("\r\n", type.Script(_options).Cast<string>()));
        }
        foreach (UserDefinedTableType type in sourceDb.UserDefinedTableTypes)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(type.Name.ToLower()) && !_objectsToCast.Contains($"{type.Schema}.{type.Name}".ToLower())) continue;
            
            var fileName = Path.Combine(castPath, $"{type.Schema}.{type.Name}.sql");
            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, string.Join("\r\n", type.Script(_options).Cast<string>()));
        }
    }

    private void ScriptUserDefinedFunctions(Database sourceDb)
    {
        _progressLog.Info("Casting Function Scripts（生成函数脚本）");
        sourceDb.PrefetchObjects(typeof(UserDefinedFunction), _options);
        var castPath = Path.Combine(_templatePath, "Functions");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (UserDefinedFunction function in sourceDb.UserDefinedFunctions)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(function.Name.ToLower()) && !_objectsToCast.Contains($"{function.Schema}.{function.Name}".ToLower())) continue;
            if (function.IsSystemObject || function.IsEncrypted || function.Schema.EqualsIgnoringCase("SchemaSmith")) continue;

            var fileName = Path.Combine(castPath, $"{function.Schema}.{function.Name}.sql");
            var sql = @$"SET ANSI_NULLS {(function.AnsiNullsStatus ? "ON" : "OFF")}
SET QUOTED_IDENTIFIER {(function.QuotedIdentifierStatus ? "ON" : "OFF")}
GO{(_scriptDynamicDependencyRemovalForFunctions ? @$"

DECLARE @v_SearchTerm VARCHAR(2000) = '%{function.Name}%'
DECLARE @v_SQL VARCHAR(MAX) = STUFF((SELECT ';' + CHAR(13) + CHAR(10) + Task
                                       FROM (SELECT 'IF EXISTS (SELECT * FROM sys.check_constraints WHERE [name] = ''' + OBJECT_NAME(cc.[name]) + ''' AND parent_object_id = ' + CONVERT(VARCHAR(20), cc.parent_object_id) + ') ' +
                                                    'ALTER TABLE [' + OBJECT_SCHEMA_NAME(cc.parent_object_id) + '].[' + OBJECT_NAME(cc.parent_object_id) + '] DROP CONSTRAINT [' + OBJECT_NAME(cc.[name]) + ']' AS Task
                                               FROM sys.check_constraints cc
                                               WHERE cc.[definition] LIKE @v_SearchTerm
                                                  OR EXISTS (SELECT *
                                                               FROM sys.computed_columns cc2
                                                               WHERE cc2.[definition] LIKE @v_SearchTerm
                                                                 AND cc2.[object_id] = cc.parent_object_id
                                                                 AND cc2.column_id = cc.parent_column_id)
                                             UNION ALL
                                             SELECT 'IF EXISTS (SELECT * FROM sys.default_constraints WHERE [name] = ''' + OBJECT_NAME(dc.[name]) + ''' AND parent_object_id = ' + CONVERT(VARCHAR(20), dc.parent_object_id) + ') ' +
                                                    'ALTER TABLE [' + OBJECT_SCHEMA_NAME(dc.parent_object_id) + '].[' + OBJECT_NAME(dc.parent_object_id) + '] DROP CONSTRAINT [' + OBJECT_NAME(dc.[name]) + ']'
                                               FROM sys.default_constraints dc
                                               WHERE dc.[definition] LIKE @v_SearchTerm
                                                  OR EXISTS (SELECT *
                                                               FROM sys.computed_columns cc
                                                               WHERE cc.[definition] LIKE @v_SearchTerm
                                                                 AND cc.[object_id] = dc.parent_object_id
                                                                 AND cc.column_id = dc.parent_column_id)
                                             UNION ALL
                                             SELECT 'IF EXISTS (SELECT * FROM sys.foreign_keys WHERE [name] = ''' + OBJECT_NAME(fk.[name]) + ''' AND parent_object_id = ' + CONVERT(VARCHAR(20), fk.parent_object_id) + ') ' +
                                                    'ALTER TABLE [' + OBJECT_SCHEMA_NAME(fk.parent_object_id) + '].[' + OBJECT_NAME(fk.parent_object_id) + '] DROP CONSTRAINT [' + OBJECT_NAME(fk.[name]) + ']'
                                               FROM sys.foreign_keys fk
                                               WHERE EXISTS (SELECT *
                                                               FROM sys.computed_columns cc
                                                               JOIN sys.foreign_key_columns fc ON fk.[object_id] = fk.[object_id]
                                                                                              AND ((fc.parent_object_id = cc.[object_id] AND fc.parent_column_id = cc.column_id)
                                                                                                OR (fc.referenced_object_id = cc.[object_id] AND fc.referenced_column_id = cc.column_id))
                                                               WHERE cc.[definition] LIKE @v_SearchTerm)
                                             UNION ALL
                                             SELECT 'IF EXISTS (SELECT * FROM sys.indexes WHERE [name] = ''' + si.[name] + ''' AND [object_id] = ' + CONVERT(VARCHAR(20), si.[object_id]) + ') ' +
                                                    'DROP INDEX [' + si.[name] + '] ON [' + OBJECT_SCHEMA_NAME(si.[object_id]) + '].[' + OBJECT_NAME(si.[object_id]) + ']'
                                               FROM sys.indexes si
                                               WHERE si.filter_definition LIKE @v_SearchTerm
                                                  OR EXISTS (SELECT *
                                                               FROM sys.computed_columns cc
                                                               JOIN sys.index_columns ic ON ic.[object_id] = si.[object_id]
                                                                                        AND ic.index_id = si.index_id
                                                                                        AND ic.column_id = cc.column_id
                                                               WHERE cc.[definition] LIKE @v_SearchTerm
                                                                 AND cc.[object_id] = si.[object_id])
                                             UNION ALL
                                             SELECT 'IF EXISTS (SELECT * FROM sys.columns WHERE [name] = ''' + cc.[name] + ''' AND [object_id] = ' + CONVERT(VARCHAR(20), cc.[object_id]) + ') ' +
                                                    'ALTER TABLE [' + OBJECT_SCHEMA_NAME(cc.[object_id]) + '].[' + OBJECT_NAME(cc.[object_id]) + '] DROP COLUMN [' + cc.[name] + ']'
                                               FROM sys.computed_columns cc
                                               WHERE cc.[definition] LIKE @v_SearchTerm) x
                                       FOR XML PATH(''), TYPE).value('.', 'VARCHAR(MAX)'), 1, 3, '') + ';'
EXEC(@v_SQL) -- 更新函数前移除依赖
GO" : "")}
{function.ScriptHeader(ScriptNameObjectBase.ScriptHeaderType.ScriptHeaderForCreateOrAlter)}
{function.TextBody}
GO
{AddExtendedProperiesScript(function.ExtendedProperties)}";
            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, sql);
        }
    }

    private string AddExtendedProperiesScript(ExtendedPropertyCollection properties)
    {
        if (properties.Count == 0) return "";

        return properties.Count == 0 ? "" : $"{string.Join("\r\n", properties.Cast<ExtendedProperty>().SelectMany(p => p.Script(_options).Cast<string>()))}\r\nGO";
    }

    private void ScriptViews(Database sourceDb)
    {
        _progressLog.Info("Casting View Scripts（生成视图脚本）");
        sourceDb.PrefetchObjects(typeof(View), _options);
        var castPath = Path.Combine(_templatePath, "Views");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (View view in sourceDb.Views)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(view.Name.ToLower()) && !_objectsToCast.Contains($"{view.Schema}.{view.Name}".ToLower())) continue;
            if (view.IsSystemObject || view.IsEncrypted || view.Schema.EqualsIgnoringCase("SchemaSmith")) continue;

            var fileName = Path.Combine(castPath, $"{view.Schema}.{view.Name}.sql");
            var sql = @$"SET ANSI_NULLS {(view.AnsiNullsStatus ? "ON" : "OFF")}
SET QUOTED_IDENTIFIER {(view.QuotedIdentifierStatus ? "ON" : "OFF")}
GO
{view.ScriptHeader(ScriptNameObjectBase.ScriptHeaderType.ScriptHeaderForCreateOrAlter)}
{view.TextBody}
GO
{AddExtendedProperiesScript(view.ExtendedProperties)}";
            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, sql);
        }
    }

    private void ScriptStoredProcedures(Database sourceDb)
    {
        _progressLog.Info("Casting Stored Procedure Scripts（生成存储过程脚本）");
        sourceDb.PrefetchObjects(typeof(StoredProcedure), _options);
        var castPath = Path.Combine(_templatePath, "Procedures");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (StoredProcedure procedure in sourceDb.StoredProcedures)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(procedure.Name.ToLower()) && !_objectsToCast.Contains($"{procedure.Schema}.{procedure.Name}".ToLower())) continue;
            if (procedure.IsSystemObject || procedure.IsEncrypted || procedure.Schema.EqualsIgnoringCase("SchemaSmith")) continue;

            var fileName = Path.Combine(castPath, $"{procedure.Schema}.{procedure.Name}.sql");
            var sql = @$"SET ANSI_NULLS {(procedure.AnsiNullsStatus ? "ON" : "OFF")}
SET QUOTED_IDENTIFIER {(procedure.QuotedIdentifierStatus ? "ON" : "OFF")}
GO
{procedure.ScriptHeader(ScriptNameObjectBase.ScriptHeaderType.ScriptHeaderForCreateOrAlter)}
{procedure.TextBody}
GO
{AddExtendedProperiesScript(procedure.ExtendedProperties)}";

            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, sql);
        }
    }

    private void ScriptTableTriggers(Database sourceDb)
    {
        _progressLog.Info("Casting Table Trigger Scripts（生成表触发器脚本）");
        sourceDb.PrefetchObjects(typeof(Table), _options);
        var castPath = Path.Combine(_templatePath, "Triggers");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (Table table in sourceDb.Tables)
        {
            if (table.IsSystemObject || table.Schema.EqualsIgnoringCase("SchemaSmith")) continue;

            foreach (Trigger trigger in table.Triggers)
            {
                if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(trigger.Name.ToLower())) continue;
                if (trigger.IsSystemObject || trigger.IsEncrypted) continue;

                var fileName = Path.Combine(castPath, $"{table.Schema}.{table.Name}.{trigger.Name}.sql");
                var sql = @$"SET ANSI_NULLS {(trigger.AnsiNullsStatus ? "ON" : "OFF")}
SET QUOTED_IDENTIFIER {(trigger.QuotedIdentifierStatus ? "ON" : "OFF")}
GO
{trigger.ScriptHeader(ScriptNameObjectBase.ScriptHeaderType.ScriptHeaderForCreateOrAlter)}
{trigger.TextBody}
GO
{AddExtendedProperiesScript(trigger.ExtendedProperties)}";
                _progressLog.Info($"  Casting {fileName}（生成脚本）");
                FileWrapper.GetFromFactory().WriteAllText(fileName, sql);
            }
        }
    }

    private void ExtractTableDefinitions(IDbCommand command, string targetDb)
    {
        using var connectionJson = GetConnection(targetDb);
        using var commandJson = connectionJson.CreateCommand();

        command.CommandText = @"
SELECT TABLE_SCHEMA, TABLE_NAME
  FROM INFORMATION_SCHEMA.TABLES t
  JOIN sys.objects so ON so.[object_id] = OBJECT_ID(t.TABLE_SCHEMA + '.' + t.TABLE_NAME)
                     AND so.is_ms_shipped = 0
  WHERE TABLE_TYPE = 'BASE TABLE'
    AND TABLE_NAME NOT LIKE 'MSPeer[_]%'
    AND TABLE_NAME NOT LIKE 'MSPub[_]%'
    AND TABLE_NAME NOT LIKE 'sys%'
    AND TABLE_SCHEMA <> 'SchemaSmith'
  ORDER BY 1, 2
";

        _progressLog.Info("Casting Table Structures（生成表结构）");
        var tableDir = Path.Combine(_templatePath, "Tables");
        DirectoryWrapper.GetFromFactory().CreateDirectory(tableDir);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains($"{reader["TABLE_NAME"]}".ToLower()) && !_objectsToCast.Contains($"{reader["TABLE_SCHEMA"]}.{reader["TABLE_NAME"]}".ToLower())) continue;

            _progressLog.Info($"  Cast table definition for {reader["TABLE_SCHEMA"]}.{reader["TABLE_NAME"]}（生成表定义）");
            commandJson.CommandText = $"EXEC SchemaSmith.GenerateTableJSON @p_Schema = '{reader["TABLE_SCHEMA"]}', @p_Table = '{reader["TABLE_NAME"]}'";

            var tableXml = commandJson.ExecuteScalar()?.ToString();
            if (string.IsNullOrWhiteSpace(tableXml))
            {
                _progressLog.Error($"    No xml returned for {reader["TABLE_SCHEMA"]}.{reader["TABLE_NAME"]}（未返回 xml）");
                continue;
            }

            var filename = Path.Combine(tableDir, $"{reader["TABLE_SCHEMA"]}.{reader["TABLE_NAME"]}.json");
            _progressLog.Info($"    Casting {filename}（生成脚本）");
            var serializer = new XmlSerializer(typeof(Schema.Domain.Table));
            Schema.Domain.Table table;
            using (var stringReader = new StringReader(tableXml))
            {
                table = (Schema.Domain.Table)serializer.Deserialize(stringReader);
            }
            var json = JsonConvert.SerializeObject(table, Formatting.Indented);
            _ = JsonConvert.DeserializeObject<Schema.Domain.Table>(json); // 确保 json 有效
            FileWrapper.GetFromFactory().WriteAllText(filename, json);
        }
    }

    private void ScriptFullTextCatalogs(Database sourceDb)
    {
        _progressLog.Info("Casting FullText Catalog Scripts（生成全文目录脚本）");
        var castPath = Path.Combine(_templatePath, "FullTextCatalogs");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (FullTextCatalog catalog in sourceDb.FullTextCatalogs)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(catalog.Name.ToLower())) continue;
            
            var fileName = Path.Combine(castPath, $"{catalog.Name}.sql");
            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, string.Join("\r\nGO\r\n", catalog.Script(_options).Cast<string>()));
        }
    }

    private void ScriptFullTextStopLists(Database sourceDb)
    {
        _progressLog.Info("Casting FullText Stop List Scripts（生成全文停用词表脚本）");
        var castPath = Path.Combine(_templatePath, "FullTextStopLists");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (FullTextStopList list in sourceDb.FullTextStopLists)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(list.Name.ToLower())) continue;

            var fileName = Path.Combine(castPath, $"{list.Name}.sql");
            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, string.Join("\r\nGO\r\n", list.Script(_options).Cast<string>()));
        }
    }

    private void ScriptDDLTriggers(Database sourceDb)
    {
        _progressLog.Info("Casting Database DDL Trigger Scripts（生成数据库 DDL 触发器脚本）");
        var castPath = Path.Combine(_templatePath, "DDLTriggers");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (DatabaseDdlTrigger trigger in sourceDb.Triggers)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(trigger.Name.ToLower())) continue;

            var fileName = Path.Combine(castPath, $"{trigger.Name}.sql");
            var sql = @$"SET ANSI_NULLS {(trigger.AnsiNullsStatus ? "ON" : "OFF")}
SET QUOTED_IDENTIFIER {(trigger.QuotedIdentifierStatus ? "ON" : "OFF")}
GO
{trigger.ScriptHeader(ScriptNameObjectBase.ScriptHeaderType.ScriptHeaderForCreateOrAlter)}
{trigger.TextBody}
GO
{AddExtendedProperiesScript(trigger.ExtendedProperties)}";
            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, sql);
        }
    }

    private void ScriptXmlSchemaCollections(Database sourceDb)
    {
        _progressLog.Info("Casting XML Schema Collection Scripts（生成 XML 架构集合脚本）");
        var castPath = Path.Combine(_templatePath, "XMLSchemaCollections");
        DirectoryWrapper.GetFromFactory().CreateDirectory(castPath);
        foreach (XmlSchemaCollection collection in sourceDb.XmlSchemaCollections)
        {
            if (_objectsToCast.Length > 0 && !_objectsToCast.Contains(collection.Name.ToLower()) && !_objectsToCast.Contains($"{collection.Schema}.{collection.Name}".ToLower())) continue;

            var fileName = Path.Combine(castPath, $"{collection.Schema}.{collection.Name}.sql");
            _progressLog.Info($"  Casting {fileName}（生成脚本）");
            FileWrapper.GetFromFactory().WriteAllText(fileName, string.Join("\r\nGO\r\n", collection.Script(_options).Cast<string>().Select(FormatXmlInScript)));
        }
    }

    private static string FormatXmlInScript(string script)
    {
        if (!script.Contains(" AS N'")) return script;
        
        var xmlStart = script.IndexOfIgnoringCase(" AS N'") + 6;
        var xml = script.Substring(xmlStart, script.Length - (xmlStart + 1));
        var formattedXml = "\r\n" + string.Join("\r\n", xml.Replace("</xsd:schema>", "</xsd:schema>\r").Split('\r').Select(FormatXml));
        return script.Replace(xml, formattedXml);
    }

    private static string FormatXml(string xml)
    {
        try
        {
            return string.IsNullOrWhiteSpace(xml) ? xml : XDocument.Parse(xml).ToString();
        }
        catch
        {
            return xml; // 如果解析失败则返回未格式化内容
        }
    }
}
