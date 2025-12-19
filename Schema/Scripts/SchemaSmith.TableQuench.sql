IF OBJECT_ID('SchemaSmith.TableQuench', 'P') IS NOT NULL
  DROP PROCEDURE [SchemaSmith].[TableQuench]
GO

CREATE PROCEDURE [SchemaSmith].[TableQuench] 
  @ProductName NVARCHAR(50),
  @TableDefinitions XML,
  @WhatIf BIT = 0,
  @DropUnknownIndexes BIT = 0,
  @DropTablesRemovedFromProduct BIT = 1,
  @UpdateFillFactor BIT = 1
AS
BEGIN TRY
  DECLARE @v_SQL NVARCHAR(MAX) = '',
          @v_DatabaseCollation NVARCHAR(200) = CAST(DATABASEPROPERTYEX(DB_NAME(), 'COLLATION') AS NVARCHAR(200))
  SET NOCOUNT ON
  RAISERROR('Parse Tables from Xml（解析表）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#TableDefinitions') IS NOT NULL DROP TABLE #TableDefinitions
  SELECT [Schema] = SchemaSmith.fn_SafeBracketWrap(ISNULL(TableNode.value('(Schema/text())[1]', 'NVARCHAR(500)'), 'dbo')),
         [Name] = SchemaSmith.fn_SafeBracketWrap(TableNode.value('(Name/text())[1]', 'NVARCHAR(500)')),
         [CompressionType] = ISNULL(NULLIF(RTRIM(TableNode.value('(CompressionType/text())[1]', 'NVARCHAR(100)')), ''), 'NONE'), 
         [IsTemporal] = ISNULL(TableNode.value('(IsTemporal/text())[1]', 'BIT'), 0),
         [OldName] = SchemaSmith.fn_SafeBracketWrap(TableNode.value('(OldName/text())[1]', 'NVARCHAR(500)')),
         [Indexes] = TableNode.query('Indexes'),
         [XmlIndexes] = TableNode.query('XmlIndexes'),
         [Columns] = TableNode.query('Columns'),
         [Statistics] = TableNode.query('Statistics'),
         [FullTextIndex] = TableNode.query('FullTextIndex'),
         [ForeignKeys] = TableNode.query('ForeignKeys'),
         [CheckConstraints] = TableNode.query('CheckConstraints')
    INTO #TableDefinitions
    FROM @TableDefinitions.nodes('/Tables/Table') AS t(TableNode);

  IF OBJECT_ID('tempdb..#Tables') IS NOT NULL DROP TABLE #Tables
  SELECT [Schema], [Name], [CompressionType], [IsTemporal], [OldName],
         CONVERT(BIT, CASE WHEN OBJECT_ID([Schema] + '.' + [Name], 'U') IS NULL AND OBJECT_ID([Schema] + '.' + [OldName], 'U') IS NULL THEN 1 ELSE 0 END) AS NewTable
    INTO #Tables
    FROM #TableDefinitions WITH (NOLOCK)
  
  RAISERROR('Parse Columns from Xml（解析列）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#Columns') IS NOT NULL DROP TABLE #Columns
  SELECT t.[Schema], t.[Name] AS [TableName], [ColumnName] = SchemaSmith.fn_SafeBracketWrap(c.[ColumnName]), [DataType] = REPLACE(c.[DataType], 'ROWVERSION', 'TIMESTAMP'), 
         [Nullable] = ISNULL(c.[Nullable], 0), c.[Default], c.[CheckExpression], c.[ComputedExpression], [Persisted] = ISNULL(c.[Persisted], 0),
         [Sparse] = ISNULL(c.[Sparse], 0), [Collation] = RTRIM(ISNULL(c.[Collation], '')), [DataMaskFunction] = RTRIM(ISNULL(c.[DataMaskFunction], '')),
         [OldName] = SchemaSmith.fn_SafeBracketWrap(c.[OldName]),
         CONVERT(BIT, CASE WHEN NOT EXISTS (SELECT * FROM #Tables x WHERE x.[Name] = t.[Name] AND x.[Schema] = t.[Schema] AND x.NewTable = 1)
                            AND COLUMNPROPERTY(OBJECT_ID(t.[Schema] + '.' + t.[Name], 'U'), SchemaSmith.fn_StripBracketWrapping([ColumnName]), 'ColumnId') IS NULL
                           THEN 1 ELSE 0 END) AS NewColumn,
         SchemaSmith.fn_SafeBracketWrap(c.[ColumnName]) + ' ' +
         -- 对于计算列，仅需表达式
         CASE WHEN RTRIM(ISNULL([ComputedExpression], '')) <> '' THEN 'AS (' + ComputedExpression + ')' + CASE WHEN ISNULL(c.[Persisted], 0) = 1 THEN ' PERSISTED' ELSE '' END
              -- 否则构建列定义
              ELSE UPPER(REPLACE(c.[DataType], 'ROWVERSION', 'TIMESTAMP')) + CASE WHEN ISNULL(Nullable, 0) = 1 THEN ' NULL' ELSE ' NOT NULL' END +
                   CASE WHEN RTRIM(ISNULL([Default], '')) <> '' THEN ' DEFAULT ' + [Default] ELSE '' END
              END AS [ColumnScript]
    INTO #Columns
    FROM #TableDefinitions t WITH (NOLOCK)
    CROSS APPLY t.[Columns].nodes('/Columns/Column') c(ColumnNode)
    CROSS APPLY (SELECT [ColumnName] = ColumnNode.value('(Name/text())[1]', 'NVARCHAR(500)'),
                        [DataType] = ColumnNode.value('(DataType/text())[1]', 'NVARCHAR(100)'),
                        [Nullable] = ColumnNode.value('(Nullable/text())[1]', 'BIT'),
                        [Default] = ColumnNode.value('(Default/text())[1]', 'NVARCHAR(MAX)'),
                        [CheckExpression] = ColumnNode.value('(CheckExpression/text())[1]', 'NVARCHAR(MAX)'),
                        [ComputedExpression] = ColumnNode.value('(ComputedExpression/text())[1]', 'NVARCHAR(MAX)'),
                        [Persisted] = ColumnNode.value('(Persisted/text())[1]', 'BIT'),
                        [Sparse] = ColumnNode.value('(Sparse/text())[1]', 'BIT'),
                        [Collation] = ColumnNode.value('(Collation/text())[1]', 'NVARCHAR(500)'),
                        [DataMaskFunction] = ColumnNode.value('(DataMaskFunction/text())[1]', 'NVARCHAR(500)'),
                        [OldName] = ColumnNode.value('(OldName/text())[1]', 'NVARCHAR(500)')) c;

  -- 不要尝试应用没有列的表
  DELETE FROM #Tables
    WHERE NOT EXISTS (SELECT * FROM #Columns C WITH (NOLOCK) WHERE C.[Schema] = #Tables.[Schema] AND C.[TableName] = #Tables.[Name])
  DELETE FROM #TableDefinitions
    WHERE NOT EXISTS (SELECT * FROM #Columns C WITH (NOLOCK) WHERE C.[Schema] = #TableDefinitions.[Schema] AND C.[TableName] = #TableDefinitions.[Name])
  
  RAISERROR('Parse Indexes from Xml（解析索引）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#Indexes') IS NOT NULL DROP TABLE #Indexes
  SELECT t.[Schema], t.[Name] AS [TableName], [IndexName] = SchemaSmith.fn_SafeBracketWrap(i.[IndexName]), [CompressionType] = ISNULL(NULLIF(RTRIM(i.[CompressionType]), ''), 'NONE'), 
         [PrimaryKey] = ISNULL(i.[PrimaryKey], 0), [Unique] = COALESCE(NULLIF(i.[Unique], 0), NULLIF(i.[PrimaryKey], 0), i.[UniqueConstraint], 0),
         [UniqueConstraint] = ISNULL(i.[UniqueConstraint], 0), [Clustered] = ISNULL(i.[Clustered], 0), [ColumnStore] = ISNULL(i.[ColumnStore], 0), [FillFactor] = ISNULL(NULLIF(i.[FillFactor], 0), 100),
         i.[FilterExpression], 
         [IndexColumns] = STUFF((SELECT ',' + CAST(CASE WHEN RTRIM([Value]) LIKE '% DESC' 
                                                        THEN SchemaSmith.fn_SafeBracketWrap(SUBSTRING(RTRIM([Value]), 1, LEN(RTRIM([Value])) - 5)) + ' DESC'
                                                        ELSE SchemaSmith.fn_SafeBracketWrap([Value])
                                                        END AS NVARCHAR(MAX))
                                   FROM SchemaSmith.fn_SplitCsv(i.[IndexColumns])
                                   WHERE SchemaSmith.fn_StripBracketWrapping(RTRIM(LTRIM([Value]))) <> ''
                                   FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
         [IncludeColumns] = STUFF((SELECT ',' + CAST(SchemaSmith.fn_SafeBracketWrap([Value]) AS NVARCHAR(MAX))
                                     FROM SchemaSmith.fn_SplitCsv(i.[IncludeColumns])
                                     WHERE SchemaSmith.fn_StripBracketWrapping(RTRIM(LTRIM([Value]))) <> ''
                                     ORDER BY SchemaSmith.fn_SafeBracketWrap([Value])
                                     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '')
    INTO #Indexes
    FROM #TableDefinitions t WITH (NOLOCK)
    CROSS APPLY t.[Indexes].nodes('/Indexes/Index') i(IndexNode)
    CROSS APPLY (SELECT [IndexName] = IndexNode.value('(Name/text())[1]', 'NVARCHAR(500)'),
                        [CompressionType] = IndexNode.value('(CompressionType/text())[1]', 'NVARCHAR(100)'),
                        [PrimaryKey] = IndexNode.value('(PrimaryKey/text())[1]', 'BIT'),
                        [Unique] = IndexNode.value('(Unique/text())[1]', 'BIT'),
                        [UniqueConstraint] = IndexNode.value('(UniqueConstraint/text())[1]', 'BIT'),
                        [Clustered] = IndexNode.value('(Clustered/text())[1]', 'BIT'),
                        [ColumnStore] = IndexNode.value('(ColumnStore/text())[1]', 'BIT'),
                        [FillFactor] = IndexNode.value('(FillFactor/text())[1]', 'TINYINT'),
                        [FilterExpression] = IndexNode.value('(FilterExpression/text())[1]', 'NVARCHAR(MAX)'),
                        [IndexColumns] = IndexNode.value('(IndexColumns/text())[1]', 'NVARCHAR(MAX)'),
                        [IncludeColumns] = IndexNode.value('(IncludeColumns/text())[1]', 'NVARCHAR(MAX)')) i;
  
  RAISERROR('Parse XML Indexes from Xml（解析 XML 索引）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#XmlIndexes') IS NOT NULL DROP TABLE #XmlIndexes
  SELECT t.[Schema], t.[Name] AS [TableName], [IndexName] = SchemaSmith.fn_SafeBracketWrap(i.[IndexName]), i.[IsPrimary],
         [Column] = SchemaSmith.fn_SafeBracketWrap(i.[Column]), [PrimaryIndex] = SchemaSmith.fn_SafeBracketWrap(i.[PrimaryIndex]),
         i.[SecondaryIndexType]
    INTO #XmlIndexes
    FROM #TableDefinitions t WITH (NOLOCK)
    CROSS APPLY t.[XmlIndexes].nodes('/XmlIndexes/XmlIndex') i(IndexNode)
    CROSS APPLY (SELECT [IndexName] = IndexNode.value('(Name/text())[1]', 'NVARCHAR(500)'),
                        [IsPrimary] = IndexNode.value('(IsPrimary/text())[1]', 'BIT'),
                        [Column] = IndexNode.value('(Column/text())[1]', 'NVARCHAR(500)'),
                        [PrimaryIndex] = IndexNode.value('(PrimaryIndex/text())[1]', 'NVARCHAR(500)'),
                        [SecondaryIndexType] = IndexNode.value('(SecondaryIndexType/text())[1]', 'NVARCHAR(500)')) i;

  RAISERROR('Parse Foreign Keys from Xml（解析外键）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#ForeignKeys') IS NOT NULL DROP TABLE #ForeignKeys
  SELECT t.[Schema], t.[Name] AS [TableName], [KeyName] = SchemaSmith.fn_SafeBracketWrap(f.[KeyName]), 
         [RelatedTableSchema] = SchemaSmith.fn_SafeBracketWrap(ISNULL(f.[RelatedTableSchema], 'dbo')), [RelatedTable] = SchemaSmith.fn_SafeBracketWrap(f.[RelatedTable]), 
         [Columns] = STUFF((SELECT ',' + CAST(SchemaSmith.fn_SafeBracketWrap([Value]) AS NVARCHAR(MAX))
                              FROM SchemaSmith.fn_SplitCsv(f.[Columns])
                              WHERE SchemaSmith.fn_StripBracketWrapping(RTRIM(LTRIM([Value]))) <> ''
                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
         [RelatedColumns] = STUFF((SELECT ',' + CAST(SchemaSmith.fn_SafeBracketWrap([Value]) AS NVARCHAR(MAX))
                                     FROM SchemaSmith.fn_SplitCsv(f.[RelatedColumns])
                                     WHERE SchemaSmith.fn_StripBracketWrapping(RTRIM(LTRIM([Value]))) <> ''
                                     FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, ''),
         [DeleteAction] = ISNULL(NULLIF(RTRIM([DeleteAction]), ''), 'NO ACTION'),
         [UpdateAction] = ISNULL(NULLIF(RTRIM([UpdateAction]), ''), 'NO ACTION')
    INTO #ForeignKeys
    FROM #TableDefinitions t WITH (NOLOCK)
    CROSS APPLY t.[ForeignKeys].nodes('/ForeignKeys/ForeignKey') f(FkNode)
    CROSS APPLY (SELECT [KeyName] = FkNode.value('(Name/text())[1]', 'NVARCHAR(500)'),
                        [Columns] = FkNode.value('(Columns/text())[1]', 'NVARCHAR(MAX)'),
                        [RelatedTableSchema] = FkNode.value('(RelatedTableSchema/text())[1]', 'NVARCHAR(500)'),
                        [RelatedTable] = FkNode.value('(RelatedTable/text())[1]', 'NVARCHAR(500)'),
                        [RelatedColumns] = FkNode.value('(RelatedColumns/text())[1]', 'NVARCHAR(MAX)'),
                        [DeleteAction] = FkNode.value('(DeleteAction/text())[1]', 'NVARCHAR(20)'),
                        [UpdateAction] = FkNode.value('(UpdateAction/text())[1]', 'NVARCHAR(20)')) f;
  
  RAISERROR('Parse Table Level Check Constraints from Xml（解析表级检查约束）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#CheckConstraints') IS NOT NULL DROP TABLE #CheckConstraints
  SELECT t.[Schema], t.[Name] AS [TableName], c.[ConstraintName], c.[Expression]
    INTO #CheckConstraints
    FROM #TableDefinitions t WITH (NOLOCK)
    CROSS APPLY t.[CheckConstraints].nodes('/CheckConstraints/CheckConstraint') c(CheckNode)
    CROSS APPLY (SELECT [ConstraintName] = CheckNode.value('(Name/text())[1]', 'NVARCHAR(500)'),
                        [Expression] = CheckNode.value('(Expression/text())[1]', 'NVARCHAR(MAX)')) c;
  
  RAISERROR('Parse Statistics from Xml（解析统计信息）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#Statistics') IS NOT NULL DROP TABLE #Statistics
  SELECT t.[Schema], t.[Name] AS [TableName], [StatisticName] = SchemaSmith.fn_SafeBracketWrap(s.[StatisticName]), [SampleSize] = ISNULL(s.[SampleSize], 0), s.[FilterExpression],
         [Columns] = STUFF((SELECT ',' + CAST(SchemaSmith.fn_SafeBracketWrap([Value]) AS NVARCHAR(MAX))
                              FROM SchemaSmith.fn_SplitCsv(s.[Columns])
                              WHERE SchemaSmith.fn_StripBracketWrapping(RTRIM(LTRIM([Value]))) <> ''
                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '')
    INTO #Statistics
    FROM #TableDefinitions t WITH (NOLOCK)
    CROSS APPLY t.[Statistics].nodes('/Statistics/Statistic') s(StatNode)
    CROSS APPLY (SELECT [StatisticName] = StatNode.value('(Name/text())[1]', 'NVARCHAR(500)'),
                        [SampleSize] = StatNode.value('(SampleSize/text())[1]', 'TINYINT'),
                        [FilterExpression] = StatNode.value('(FilterExpression/text())[1]', 'NVARCHAR(MAX)'),
                        [Columns] = StatNode.value('(Columns/text())[1]', 'NVARCHAR(MAX)')) s;
  
  RAISERROR('Parse Full Text Indexes from Xml（解析全文索引）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#FullTextIndexes') IS NOT NULL DROP TABLE #FullTextIndexes
  SELECT t.[Schema], t.[Name] AS [TableName], [FullTextCatalog] = SchemaSmith.fn_SafeBracketWrap(f.[FullTextCatalog]), [KeyIndex] = SchemaSmith.fn_SafeBracketWrap(f.[KeyIndex]), 
         f.[ChangeTracking], [StopList] = SchemaSmith.fn_SafeBracketWrap(COALESCE(NULLIF(RTRIM(f.[StopList]), ''), 'SYSTEM')),
         [Columns] = STUFF((SELECT ',' + CAST(SchemaSmith.fn_SafeBracketWrap([Value]) AS NVARCHAR(MAX))
                              FROM SchemaSmith.fn_SplitCsv(f.[Columns])
                              WHERE SchemaSmith.fn_StripBracketWrapping(RTRIM(LTRIM([Value]))) <> ''
                              FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '')
    INTO #FullTextIndexes
    FROM #TableDefinitions t WITH (NOLOCK)
    CROSS APPLY t.[FullTextIndex].nodes('/FullTextIndex') f(FullTextNode)
    CROSS APPLY (SELECT [Columns] = FullTextNode.value('(Columns/text())[1]', 'NVARCHAR(MAX)'),
                        [FullTextCatalog] = FullTextNode.value('(FullTextCatalog/text())[1]', 'NVARCHAR(500)'),
                        [KeyIndex] = FullTextNode.value('(KeyIndex/text())[1]', 'NVARCHAR(500)'),
                        [ChangeTracking] = FullTextNode.value('(ChangeTracking/text())[1]', 'NVARCHAR(500)'),
                        [StopList] = FullTextNode.value('(StopList/text())[1]', 'NVARCHAR(500)')) f;
  
  -- 聚集索引压缩会覆盖表压缩
  RAISERROR('Override table compression to match clustered index（根据聚集索引覆盖表压缩）', 10, 1) WITH NOWAIT
  UPDATE t
    SET [CompressionType] = CASE WHEN [ColumnStore] = 1 THEN 'COLUMNSTORE' ELSE i.[CompressionType] END
    FROM #Tables t
    JOIN #Indexes i WITH (NOLOCK) ON i.[Schema] = t.[Schema]
                                 AND i.[TableName] = t.[Name]
                                 AND i.[Clustered] = 1
 
  RAISERROR('Get Schema List（获取架构列表）', 10, 1) WITH NOWAIT
  SELECT DISTINCT t.[Schema]
    INTO #SchemaList
    FROM #Tables t WITH (NOLOCK)

  RAISERROR('Handle Table Renames（处理表重命名）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Rename ' + T.[Schema] + '.' + T.[OldName] + ' to ' + T.[Schema] + '.' + T.[Name] + '（重命名）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             'EXEC sp_rename ''' + SchemaSmith.fn_StripBracketWrapping(T.[Schema]) + '.' + SchemaSmith.fn_StripBracketWrapping(T.[OldName]) + ''', ''' + SchemaSmith.fn_StripBracketWrapping(T.[Name]) + ''';' + CHAR(13) + CHAR(10) AS NVARCHAR(MAX))
                            FROM #Tables T WITH (NOLOCK)
                            WHERE OBJECT_ID(T.[Schema] + '.' + T.[OldName]) IS NOT NULL
                              AND OBJECT_ID(T.[Schema] + '.' + T.[Name]) IS NULL
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Handle Column Renames（处理列重命名）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Rename ' + c.[Schema] + '.' + c.[TableName] + '.' + c.[OldName] + ' to ' + c.[Schema] + '.' + c.[TableName] + '.' + c.[ColumnName] + '（重命名）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             'EXEC sp_rename ''' + SchemaSmith.fn_StripBracketWrapping(c.[Schema]) + '.' + SchemaSmith.fn_StripBracketWrapping(c.[TableName]) + '.' + SchemaSmith.fn_StripBracketWrapping(c.[OldName]) + ''', ''' + SchemaSmith.fn_StripBracketWrapping(c.[ColumnName]) + ''', ''COLUMN'';' + CHAR(13) + CHAR(10) AS NVARCHAR(MAX))
                            FROM #Columns c WITH (NOLOCK)
                            WHERE COLUMNPROPERTY(OBJECT_ID(c.[Schema] + '.' + c.[TableName]), c.[OldName], 'AllowsNull') IS NOT NULL
                              AND COLUMNPROPERTY(OBJECT_ID(c.[Schema] + '.' + c.[TableName]), c.[ColumnName], 'AllowsNull') IS NULL
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Turn off Temporal Tracking for tables no longer defined temporal（关闭不再标记为时态的表的时态跟踪）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Turn OFF Temporal Tracking for ' + T.[Schema] + '.' + T.[Name] + '（关闭时态跟踪）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             'ALTER TABLE ' + T.[Schema] + '.' + T.[Name] + ' SET (SYSTEM_VERSIONING = OFF);' + CHAR(13) + CHAR(10) +
                                                             'ALTER TABLE ' + T.[Schema] + '.' + T.[Name] + ' DROP PERIOD FOR SYSTEM_TIME;' AS NVARCHAR(MAX))
                            FROM #Tables T WITH (NOLOCK)
                            WHERE t.IsTemporal = 0
                              AND OBJECTPROPERTY(OBJECT_ID([Schema] + '.' + [Name]), 'TableTemporalType') = 2
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Collect table level extended properties（收集表级扩展属性）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#TableProperties') IS NOT NULL DROP TABLE #TableProperties
  SELECT [Schema], objname COLLATE DATABASE_DEFAULT AS TableName, x.[Name] COLLATE DATABASE_DEFAULT AS PropertyName, CONVERT(NVARCHAR(50), x.[value]) COLLATE DATABASE_DEFAULT AS [value]
    INTO #TableProperties
    FROM #SchemaList WITH (NOLOCK)
    CROSS APPLY fn_listextendedproperty(default, 'Schema', SchemaSmith.fn_StripBracketWrapping([Schema]), 'Table', default, default, default) x
    WHERE x.[Name] COLLATE DATABASE_DEFAULT = 'ProductName'
  
  RAISERROR('Validate Table Ownership（校验表所属产品）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Table ' + tp.[Schema] + '.' + tp.[TableName] + ' owned by different product. [' + tp.[Value] + ']（表归属不同产品）'', 10, 1) WITH NOWAIT;' AS NVARCHAR(MAX))
                            FROM #Tables t WITH (NOLOCK)
                            JOIN #TableProperties tp WITH (NOLOCK) ON t.[Schema] = tp.[Schema]
                                                                  AND SchemaSmith.fn_StripBracketWrapping(t.[Name]) = tp.TableName
                            WHERE tp.[value] <> @ProductName
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  IF EXISTS (SELECT *
               FROM #Tables t WITH (NOLOCK)
               JOIN #TableProperties tp WITH (NOLOCK) ON t.[Schema] = tp.[Schema]
                                                     AND SchemaSmith.fn_StripBracketWrapping(t.[Name]) = tp.TableName
               WHERE tp.[value] <> @ProductName)
  BEGIN
    RAISERROR('One or more tables in this quench are already owned by another product（有一个或多个表已被其他产品拥有）', 16, 1) WITH NOWAIT
  END
  
  IF @DropTablesRemovedFromProduct = 1
  BEGIN
    RAISERROR('Identify tables removed from the product（识别已从产品中移除的表）', 10, 1) WITH NOWAIT
    IF OBJECT_ID('tempdb..#TablesRemovedFromProduct') IS NOT NULL DROP TABLE #TablesRemovedFromProduct
    SELECT tp.[Schema], tp.TableName
      INTO #TablesRemovedFromProduct
      FROM #TableProperties tp WITH (NOLOCK)
      WHERE tp.[value] = @ProductName
        AND NOT EXISTS (SELECT * 
                          FROM #Tables t WITH (NOLOCK) 
                          WHERE t.[Schema] = tp.[Schema] 
                            AND SchemaSmith.fn_StripBracketWrapping(t.[Name]) = tp.TableName)

    IF EXISTS (SELECT * FROM #TablesRemovedFromProduct WITH (NOLOCK))
    BEGIN
      RAISERROR('Drop tables removed from the product（删除已从产品中移除的表）', 10, 1) WITH NOWAIT
      SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Dropping table ' + t.[Schema] + '.' + t.[TableName] + '（删除表）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                                 'IF OBJECT_ID(''' + t.[Schema] + '.[' + t.[TableName] + ']'', ''U'') IS NOT NULL DROP TABLE ' + t.[Schema] + '.[' + t.[TableName] + '];' AS NVARCHAR(MAX))
                                FROM #TablesRemovedFromProduct t WITH (NOLOCK)
                                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
      IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
    END
  END
  
  RAISERROR('Collect index level extended properties（收集索引级扩展属性）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#IndexProperties') IS NOT NULL DROP TABLE #IndexProperties
  SELECT t.[Schema], t.[Name] AS TableName, objname COLLATE DATABASE_DEFAULT AS IndexName, x.[Name] COLLATE DATABASE_DEFAULT AS PropertyName, CONVERT(NVARCHAR(50), x.[value]) COLLATE DATABASE_DEFAULT AS [value]
    INTO #IndexProperties
    FROM #Tables t WITH (NOLOCK)
    CROSS APPLY fn_listextendedproperty(default, 'Schema', SchemaSmith.fn_StripBracketWrapping(t.[Schema]), 'Table', SchemaSmith.fn_StripBracketWrapping(t.[Name]), 'Index', default) x
    WHERE x.[Name] COLLATE DATABASE_DEFAULT = 'ProductName'
  
  RAISERROR('Identify indexes removed from the product（识别已从产品中移除的索引）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#IndexesRemovedFromProduct') IS NOT NULL DROP TABLE #IndexesRemovedFromProduct
  SELECT xp.[Schema], xp.TableName, xp.IndexName, IsConstraint = CAST(CASE WHEN OBJECT_ID(xp.[Schema] + '.' + xp.IndexName) IS NOT NULL THEN 1 ELSE 0 END AS BIT)
    INTO #IndexesRemovedFromProduct
    FROM #IndexProperties xp WITH (NOLOCK)
    WHERE xp.[value] = @ProductName
      AND NOT EXISTS (SELECT * 
                        FROM #Indexes i WITH (NOLOCK) 
                        WHERE i.[Schema] = xp.[Schema] 
                          AND i.TableName = xp.TableName
                          AND SchemaSmith.fn_StripBracketWrapping(i.IndexName) = xp.IndexName)
      AND NOT EXISTS (SELECT * 
                        FROM #XmlIndexes i WITH (NOLOCK) 
                        WHERE i.[Schema] = xp.[Schema] 
                          AND i.TableName = xp.TableName
                          AND SchemaSmith.fn_StripBracketWrapping(i.IndexName) = xp.IndexName)

  RAISERROR('Detect Column Changes（检测列变更）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#ColumnChanges') IS NOT NULL DROP TABLE #ColumnChanges
  SELECT c.[Schema], c.[TableName], c.[ColumnName],
         -- 对于计算列，仅需表达式
         CASE WHEN RTRIM(ISNULL([ComputedExpression], '')) <> '' 
              THEN 'AS (' + ComputedExpression + ')' + CASE WHEN c.[Persisted] = 1 THEN ' PERSISTED' ELSE '' END
              -- 否则需要构建列定义
              ELSE REPLACE(REPLACE(UPPER(LEFT([DataType], COALESCE(NULLIF(CHARINDEX('IDENTITY', [DataType]), 0), LEN([DataType]) + 1) - 1)), 'ROWGUIDCOL', ''), 'NOT FOR REPLICATION', '') + 
                   CASE WHEN [Collation] <> 'IGNORE' AND ISNULL(NULLIF(ic.COLLATION_NAME, @v_DatabaseCollation), '') <> [Collation] THEN ' COLLATE ' + ISNULL(NULLIF(RTRIM([Collation]), ''), @v_DatabaseCollation) ELSE '' END +
                   CASE WHEN [Sparse] = 1 THEN ' SPARSE' ELSE '' END +
                   CASE WHEN Nullable = 1 THEN ' NULL' ELSE ' NOT NULL' END
              END AS [ColumnScript],
         CASE WHEN RTRIM(ISNULL([ComputedExpression], '')) = '' 
              THEN CASE WHEN [DataType] LIKE '%ROWGUIDCOL%' AND sc.is_rowguidcol = 0 THEN ' ADD ROWGUIDCOL' ELSE '' END +
                   CASE WHEN [DataType] NOT LIKE '%ROWGUIDCOL%' AND sc.is_rowguidcol = 1 THEN ' DROP ROWGUIDCOL' ELSE '' END +
                   CASE WHEN [DataType] LIKE '%NOT FOR REPLICATION%' AND ident.is_not_for_replication = 0 THEN ' ADD NOT FOR REPLICATION' ELSE '' END +
                   CASE WHEN [DataType] NOT LIKE '%NOT FOR REPLICATION%' AND ident.is_not_for_replication = 1 THEN ' DROP NOT FOR REPLICATION' ELSE '' END +
                   CASE WHEN mc.masking_function IS NOT NULL AND ([DataMaskFunction] = '' OR mc.masking_function COLLATE DATABASE_DEFAULT <> [DataMaskFunction]) THEN ' DROP MASKED' ELSE '' END +
                   CASE WHEN [DataMaskFunction] <> '' AND mc.masking_function IS NULL THEN ' ADD MASKED WITH (FUNCTION = ''' + [DataMaskFunction] + ''')' ELSE '' END +
                   CASE WHEN [DataMaskFunction] <> '' AND mc.masking_function COLLATE DATABASE_DEFAULT <> [DataMaskFunction]
                        THEN '; ALTER TABLE ' + c.[Schema] + '.' + c.[TableName] + ' ALTER COLUMN ' + c.[ColumnName] + ' ADD MASKED WITH (FUNCTION = ''' + [DataMaskFunction] + ''')'
                        ELSE '' END
              ELSE ''
              END AS [SpecialColumnScript],
         CAST(CASE WHEN cc.[definition] IS NOT NULL OR RTRIM(ISNULL([ComputedExpression], '')) <> ''
                     OR (ident.column_id IS NULL AND [DataType] LIKE '%IDENTITY%') -- 切换为标识列需要删除并重建列
                   THEN 1 ELSE 0 END AS BIT) AS MustDropAndRecreate,
         CAST(0 AS BIT) AS DropOnly
    INTO #ColumnChanges
    FROM #Tables T WITH (NOLOCK)
    JOIN #Columns c WITH (NOLOCK) ON C.[Schema] = T.[Schema] 
                                 AND C.[TableName] = T.[Name]
                                 AND C.[NewColumn] = 0
    JOIN INFORMATION_SCHEMA.COLUMNS ic WITH (NOLOCK) ON ic.TABLE_SCHEMA = SchemaSmith.fn_StripBracketWrapping(C.[Schema])
                                                    AND ic.TABLE_NAME = SchemaSmith.fn_StripBracketWrapping(C.[TableName])
                                                    AND ic.COLUMN_NAME = SchemaSmith.fn_StripBracketWrapping(C.[ColumnName])
    JOIN sys.columns sc WITH (NOLOCK) ON sc.[object_id] = OBJECT_ID(ic.TABLE_SCHEMA + '.' + ic.TABLE_NAME) AND sc.[name] = ic.COLUMN_NAME
    JOIN (SELECT CASE WHEN SCHEMA_NAME(st.[schema_id]) IN ('sys', 'dbo')
                      THEN '' ELSE SCHEMA_NAME(st.[schema_id]) + '.' END + st.[name] AS USER_TYPE, st.user_type_id
            FROM sys.types st WITH (NOLOCK)) st ON st.user_type_id = sc.user_type_id
    LEFT JOIN sys.identity_columns ident WITH (NOLOCK) ON ident.[Name] = COLUMN_NAME
                                                      AND ident.[object_id] = OBJECT_ID(TABLE_SCHEMA + '.' + TABLE_NAME)
    LEFT JOIN sys.computed_columns cc WITH (NOLOCK) ON cc.[name] = SchemaSmith.fn_StripBracketWrapping(c.ColumnName)
                                                   AND cc.[object_id] = OBJECT_ID(C.[Schema] + '.' + C.[TableName])
    LEFT JOIN sys.masked_columns mc WITH (NOLOCK) ON mc.[name] = SchemaSmith.fn_StripBracketWrapping(c.ColumnName)
                                                 AND mc.[object_id] = OBJECT_ID(C.[Schema] + '.' + C.[TableName])
    WHERE t.NewTable = 0
      AND (REPLACE(UPPER(USER_TYPE) + CASE WHEN USER_TYPE LIKE '%CHAR' OR USER_TYPE LIKE '%BINARY'
                                           THEN '(' + CASE WHEN CHARACTER_MAXIMUM_LENGTH = -1 THEN 'MAX' ELSE CONVERT(NVARCHAR(20), CHARACTER_MAXIMUM_LENGTH) END + ')'
                                           WHEN USER_TYPE IN ('NUMERIC', 'DECIMAL')
                                           THEN  '(' + CONVERT(NVARCHAR(20), NUMERIC_PRECISION) + ', ' + CONVERT(NVARCHAR(20), NUMERIC_SCALE) + ')'
                                           WHEN USER_TYPE = 'DATETIME2'
                                           THEN  '(' + CONVERT(NVARCHAR(20), DATETIME_PRECISION) + ')'
                                           WHEN USER_TYPE = 'XML' AND sc.xml_collection_id <> 0
                                           THEN  '(' + (SELECT '[' + SCHEMA_NAME(xc.[schema_id]) + '].[' + xc.[name] + ']' FROM sys.xml_schema_collections xc WHERE xc.xml_collection_id = sc.xml_collection_id) + ')'
                                           WHEN USER_TYPE = 'UNIQUEIDENTIFIER' AND sc.is_rowguidcol = 1
                                           THEN  ' ROWGUIDCOL'
                                           ELSE '' END +
                                      CASE WHEN ident.column_id IS NOT NULL
                                           THEN ' IDENTITY(' + CONVERT(NVARCHAR(20), ident.seed_value) + ', ' + CONVERT(NVARCHAR(20), ident.increment_value) + ')' +
                                                CASE WHEN ident.is_not_for_replication = 1 THEN ' NOT FOR REPLICATION' ELSE '' END
                                           ELSE '' END, ', ', ',')  <> REPLACE(c.DataType, ', ', ',')
        OR CASE WHEN c.Nullable = 1 THEN 'YES' ELSE 'NO' END <> ic.IS_NULLABLE
        OR ISNULL(SchemaSmith.fn_StripParenWrapping(cc.[definition]), '') <> ISNULL(c.ComputedExpression, '')
        OR ISNULL(cc.is_persisted, 0) <> ISNULL(c.[Persisted], 0))
        OR sc.is_sparse <> [Sparse]
        OR ISNULL(mc.masking_function, '') COLLATE DATABASE_DEFAULT <> [DataMaskFunction]
        OR ([Collation] <> 'IGNORE' AND ISNULL(NULLIF(ic.COLLATION_NAME, @v_DatabaseCollation), '') <> [Collation])
  
  RAISERROR('Detect Computed Columns Impacted by Other Column Changes（检测受其他列变更影响的计算列）', 10, 1) WITH NOWAIT
  INSERT #ColumnChanges ([Schema], [TableName], [ColumnName], [ColumnScript], [SpecialColumnScript], MustDropAndRecreate, [DropOnly])
    SELECT C.[Schema], C.[TableName], c.[ColumnName], 
           [ColumnScript] = 'AS (' + ComputedExpression + ')' + CASE WHEN c.[Persisted] = 1 THEN ' PERSISTED' ELSE '' END, 
           [SpecialColumnScript] = '',
           MustDropAndRecreate = CAST(1 AS BIT), [DropOnly] = CAST(0 AS BIT)
      FROM #ColumnChanges cc WITH (NOLOCK)
      JOIN sys.computed_columns sc WITH (NOLOCK) ON sc.[object_id] = OBJECT_ID(cc.[Schema] + '.' + cc.[TableName])
                                                AND sc.[definition] LIKE '%' + SchemaSmith.fn_StripBracketWrapping(cc.ColumnName) + '%'
      JOIN #Columns c WITH (NOLOCK) ON C.[Schema] = cc.[Schema] 
                                   AND C.[TableName] = cc.[TableName]
                                   AND c.[ColumnName] = cc.[ColumnName]
      WHERE NOT EXISTS (SELECT * FROM #ColumnChanges cc2 WITH (NOLOCK) WHERE cc2.[Schema] = cc.[Schema] AND cc2.[TableName] = cc.[TableName] AND cc2.[ColumnName] = cc.[ColumnName])
  
  RAISERROR('Detect Column Drops（检测列删除）', 10, 1) WITH NOWAIT
  INSERT #ColumnChanges ([Schema], [TableName], [ColumnName], [ColumnScript], [SpecialColumnScript], MustDropAndRecreate, [DropOnly])
    SELECT t.[Schema], [TableName] = t.[Name], [ColumnName] = '[' + COLUMN_NAME + ']', '', '', 0, 1
      FROM #Tables t WITH (NOLOCK)
      JOIN INFORMATION_SCHEMA.COLUMNS WITH (NOLOCK) ON TABLE_SCHEMA = SchemaSmith.fn_StripBracketWrapping(t.[Schema])
                                                   AND TABLE_NAME = SchemaSmith.fn_StripBracketWrapping(t.[Name]) 
      WHERE NOT EXISTS (SELECT * 
                          FROM #Columns c WITH (NOLOCK)
                          WHERE c.[Schema] = t.[Schema]
                            AND c.[TableName] = t.[Name]
                            AND SchemaSmith.fn_StripBracketWrapping(c.[ColumnName]) = COLUMN_NAME)
        AND NOT (t.IsTemporal = 1 AND COLUMN_NAME IN ('ValidFrom', 'ValidTo'))
  
  RAISERROR('Collect Foreign Keys To Drop（收集待删除外键）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#FKsToDrop') IS NOT NULL DROP TABLE #FKsToDrop
  SELECT t.[Schema], [TableName] = t.[Name], [FKName] = fk.[Name]
    INTO #FKsToDrop
    FROM #Tables t WITH (NOLOCK)
    JOIN sys.foreign_keys fk WITH (NOLOCK) ON fk.parent_object_id = OBJECT_ID(t.[Schema] + '.' + t.[Name])
    WHERE NOT EXISTS (SELECT * FROM #ForeignKeys fk2 WITH (NOLOCK) WHERE t.[Schema] = fk2.[Schema] AND t.[Name] = fk2.[TableName] AND fk.[name] = SchemaSmith.fn_StripBracketWrapping(fk2.[KeyName]))

  RAISERROR('Drop Foreign Keys No Longer Defined In The Product（删除产品中已移除的外键）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Dropping foreign Key ' + df.[Schema] + '.' + df.[TableName] + '.' + df.[FKName] + '（删除外键）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             'IF EXISTS (SELECT * FROM sys.foreign_keys WHERE [name] = ''' + SchemaSmith.fn_StripBracketWrapping(df.[FKName]) + ''' AND parent_object_id = OBJECT_ID(''' + df.[Schema] + '.' + df.[TableName] + ''')) ' +
                                                             'ALTER TABLE ' + df.[Schema] + '.' + df.[TableName] + ' DROP CONSTRAINT ' + df.[FKName] + ';' AS NVARCHAR(MAX))
                            FROM #FKsToDrop df WITH (NOLOCK)
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Identify Fulltext Indexes To Drop Based On Column Changes（根据列变更识别待删除全文索引）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#FTIndexesToDropForChanges') IS NOT NULL DROP TABLE #FTIndexesToDropForChanges
  SELECT DISTINCT cc.[Schema], cc.[TableName]
    INTO #FTIndexesToDropForChanges
    FROM sys.fulltext_index_columns ic WITH (NOLOCK)
    JOIN #ColumnChanges cc WITH (NOLOCK) ON ic.[object_id] = OBJECT_ID(cc.[Schema] + '.' + cc.[TableName]) 
                                        AND COL_NAME(ic.[object_id], ic.column_id) = SchemaSmith.fn_StripBracketWrapping(cc.ColumnName)
  
  RAISERROR('Drop FullText Indexes Referencing Modified Columns（删除引用已修改列的全文索引）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Dropping fulltext index on ' + di.[Schema] + '.' + di.[TableName] + '（删除全文索引）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             'DROP FULLTEXT INDEX ON ' + di.[Schema] + '.' + di.[TableName] + ';' AS NVARCHAR(MAX))
                            FROM #FTIndexesToDropForChanges di WITH (NOLOCK)
                            JOIN sys.fulltext_indexes fi WITH (NOLOCK) ON fi.[object_id] = OBJECT_ID(di.[Schema] + '.' + di.[TableName])
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Collect Existing FullText Indexes（收集现有全文索引）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#ExistingFullTextIndexes') IS NOT NULL DROP TABLE #ExistingFullTextIndexes
  SELECT t.[Schema], [TableName] = t.[Name],
         STUFF((SELECT ',' + CAST('[' + COL_NAME(fc.[object_id], fc.column_id) + ']' AS NVARCHAR(MAX))
                  FROM sys.fulltext_index_columns fc WITH (NOLOCK)
                  WHERE fi.[object_id] = fc.[object_id]
                  ORDER BY COL_NAME(fc.[object_id], fc.column_id)
                  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '') AS [Columns],
         FullTextCatalog = '[' + (SELECT c.[name] COLLATE DATABASE_DEFAULT FROM sys.fulltext_catalogs c WITH (NOLOCK) WHERE c.fulltext_catalog_id = fi.fulltext_catalog_id) + ']',
         KeyIndex = '[' + (SELECT i.[Name] COLLATE DATABASE_DEFAULT FROM sys.indexes i WITH (NOLOCK) WHERE i.[object_id] = fi.[object_id] AND i.[index_id] = fi.[unique_index_id]) + ']',
         ChangeTracking = change_tracking_state_desc COLLATE DATABASE_DEFAULT,
         [StopList] = '[' + COALESCE((SELECT fs.[name] COLLATE DATABASE_DEFAULT FROM sys.fulltext_stoplists fs WITH (NOLOCK) WHERE fs.stoplist_id = fi.stoplist_id), 'SYSTEM') + ']'
    INTO #ExistingFullTextIndexes
    FROM #Tables t WITH (NOLOCK)
    JOIN sys.fulltext_indexes fi WITH (NOLOCK) ON fi.[object_id] = OBJECT_ID(t.[Schema] + '.' + t.[Name])
    WHERE t.NewTable = 0
  
  RAISERROR('Identify Indexes To Drop Based On Column Changes（根据列变更识别待删除索引）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#IndexesToDropForColumnChanges') IS NOT NULL DROP TABLE #IndexesToDropForColumnChanges
  SELECT DISTINCT cc.[Schema], cc.[TableName], IndexName = i.[name],
         IsConstraint = CAST(CASE WHEN i.is_primary_key = 1 OR i.is_unique_constraint = 1 THEN 1 ELSE 0 END AS BIT),
         IsUnique = i.is_unique,
         IsClustered = CAST(CASE WHEN i.[type_desc] = 'CLUSTERED' THEN 1 ELSE 0 END AS BIT)
    INTO #IndexesToDropForColumnChanges
    FROM sys.indexes i WITH (NOLOCK)
    JOIN #ColumnChanges cc WITH (NOLOCK) ON i.[object_id] = OBJECT_ID(cc.[Schema] + '.' + cc.[TableName]) 
    LEFT JOIN sys.index_columns ic WITH (NOLOCK) ON ic.[object_id] = i.[object_id]
                                                AND ic.[index_id] = i.[index_id]
                                                AND COL_NAME(ic.[object_id], ic.column_id) = SchemaSmith.fn_StripBracketWrapping(cc.ColumnName)
    WHERE ic.column_id IS NOT NULL
       OR i.filter_definition LIKE '%' + SchemaSmith.fn_StripBracketWrapping(cc.ColumnName) + '%'
  
  -- 处理表压缩变更
  RAISERROR('Fixup Table Compression（修正表压缩）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Altering table compression for ' + t.[Schema] + '.' + t.[Name] + ' TO ' + t.[CompressionType] + '（调整表压缩）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             'ALTER TABLE ' + t.[Schema] + '.' + t.[Name] + ' REBUILD PARTITION=ALL WITH (DATA_COMPRESSION=' + t.[CompressionType] + ');' AS NVARCHAR(MAX))
                            FROM #Tables t WITH (NOLOCK)
                            LEFT JOIN sys.partitions p WITH (NOLOCK) ON p.[object_id] = OBJECT_ID(t.[Schema] + '.' + t.[Name])
                                                                    AND p.index_id < 2
                            WHERE t.NewTable = 0
                              AND t.[CompressionType] IN ('NONE', 'ROW', 'PAGE')
                              AND COALESCE(p.data_compression_desc COLLATE DATABASE_DEFAULT, 'NONE') <> t.[CompressionType]
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  -- 处理索引压缩变更
  RAISERROR('Fixup Index Compression（修正索引压缩）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Altering index compression for ' + i.[Schema] + '.' + i.[TableName] + '.' + i.[IndexName] + ' TO ' + i.[CompressionType] + '（调整索引压缩）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             'ALTER INDEX ' + i.[IndexName] + ' ON ' + i.[Schema] + '.' + i.[TableName] + ' REBUILD PARTITION=ALL WITH (DATA_COMPRESSION=' + i.[CompressionType] + ');' AS NVARCHAR(MAX))
                            FROM #Indexes i WITH (NOLOCK) 
                            JOIN sys.indexes si WITH (NOLOCK) ON si.[object_id] = OBJECT_ID(i.[Schema] + '.' + i.[TableName])
                                                             AND si.[name] = SchemaSmith.fn_StripBracketWrapping(i.[IndexName])
                            LEFT JOIN sys.partitions p WITH (NOLOCK) ON p.[object_id] = si.[object_id]
                                                                    AND p.index_id = si.index_id
                            WHERE COALESCE(p.data_compression_desc COLLATE DATABASE_DEFAULT, 'NONE') <> i.[CompressionType]
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Collect Existing Index Definitions（收集现有索引定义）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#ExistingIndexes') IS NOT NULL DROP TABLE #ExistingIndexes
  SELECT xSchema = t.[Schema], [xTableName] = t.[Name], [xIndexName] = CAST(si.[Name] AS NVARCHAR(500)),
         IsConstraint = CAST(CASE WHEN si.is_primary_key = 1 OR si.is_unique_constraint = 1 THEN 1 ELSE 0 END AS BIT),
         IsUnique = si.is_unique, IsClustered = CAST(CASE WHEN si.[type_desc] = 'CLUSTERED' THEN 1 ELSE 0 END AS BIT), [FillFactor] = ISNULL(NULLIF(si.fill_factor, 0), 100),
         IndexScript = 'CREATE ' + 
                       CASE WHEN si.is_unique = 1 THEN 'UNIQUE ' ELSE '' END + 
                       CASE WHEN si.[type] IN (1, 5) THEN '' ELSE 'NON' END + 'CLUSTERED ' +
                       CASE WHEN si.[type] IN (5, 6) THEN 'COLUMNSTORE ' ELSE '' END +
                       'INDEX [' + si.[Name] + '] ON ' + t.[Schema] + '.' + t.[Name] + 
                       CASE WHEN si.[type] NOT IN (5, 6) 
                            THEN ' (' + (SELECT STUFF((SELECT ',' + CAST('[' + COL_NAME(ic.[object_id], ic.column_id) + ']' + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE '' END AS NVARCHAR(MAX))
                                                        FROM sys.index_columns ic WITH (NOLOCK)
                                                        WHERE si.[object_id] = ic.[object_id] AND si.index_id = ic.index_id AND is_included_column = 0
                                                        ORDER BY key_ordinal
                                                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '')) + ')' +
                                 CASE WHEN EXISTS (SELECT * FROM sys.index_columns ic WITH (NOLOCK) WHERE si.[object_id] = ic.[object_id] AND si.index_id = ic.index_id AND is_included_column = 1)
                                      THEN ' INCLUDE (' +
                                           (SELECT STUFF((SELECT ',' + CAST('[' + COL_NAME(ic.[object_id], ic.column_id) + ']' AS NVARCHAR(MAX))
                                                            FROM sys.index_columns ic WITH (NOLOCK)
                                                            WHERE si.[object_id] = ic.[object_id] AND si.index_id = ic.index_id AND is_included_column = 1
                                                            ORDER BY COL_NAME(ic.[object_id], ic.column_id)
                                                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '')) + ')'
                                      ELSE '' END
                            WHEN si.[type] IN (6) 
                            THEN ' (' + (SELECT STUFF((SELECT ',' + CAST('[' + COL_NAME(ic.[object_id], ic.column_id) + ']' AS NVARCHAR(MAX))
                                                        FROM sys.index_columns ic WITH (NOLOCK)
                                                        WHERE si.[object_id] = ic.[object_id] AND si.index_id = ic.index_id AND is_included_column = 1
                                                        ORDER BY COL_NAME(ic.[object_id], ic.column_id)
                                                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '')) + ')'
                            ELSE '' END +
                       CASE WHEN si.has_filter = 1 THEN ' WHERE ' + SchemaSmith.fn_StripParenWrapping(si.filter_definition) ELSE '' END +
                       CASE WHEN (si.[type] NOT IN (5, 6) AND ISNULL(p.[data_compression_desc], 'NONE') COLLATE DATABASE_DEFAULT IN ('NONE', 'ROW', 'PAGE'))
                              OR (si.[type] IN (5, 6) AND ISNULL(p.[data_compression_desc], 'NONE') COLLATE DATABASE_DEFAULT IN ('COLUMNSTORE', 'COLUMNSTORE_ARCHIVE'))
                            THEN ' WITH (DATA_COMPRESSION=' + ISNULL(p.[data_compression_desc], 'NONE') COLLATE DATABASE_DEFAULT + ')'
                            ELSE '' END
    INTO #ExistingIndexes
    FROM #Tables t WITH (NOLOCK)
    JOIN sys.indexes si WITH (NOLOCK) ON si.[object_id] = OBJECT_ID(t.[Schema] + '.' + t.[Name])
                                     AND si.index_id > 0
                                     AND is_hypothetical = 0
                                     AND is_disabled = 0
    LEFT JOIN sys.partitions p WITH (NOLOCK) ON p.[object_id] = si.[object_id]
                                            AND p.index_id = si.index_id
    WHERE t.NewTable = 0
      AND NOT EXISTS (SELECT * FROM sys.xml_indexes xi WHERE xi.[object_id] = si.[object_id] AND xi.index_id = si.index_id)
    
  RAISERROR('Detect Index Changes（检测索引变更）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#IndexChanges') IS NOT NULL DROP TABLE #IndexChanges
  SELECT i.[Schema], i.[TableName], i.[IndexName], ei.[IsConstraint], IsUnique = i.[Unique], IsClustered = i.[Clustered]
    INTO #IndexChanges
    FROM #ExistingIndexes ei WITH (NOLOCK)
    JOIN #Indexes i WITH (NOLOCK) ON ei.[xSchema] = i.[Schema]
                                 AND ei.[xTableName] = i.[TableName]
                                 AND ei.[xIndexName] = SchemaSmith.fn_StripBracketWrapping(i.[IndexName])
    WHERE EXISTS (SELECT * 
                    FROM sys.indexes si WITH (NOLOCK)
                    WHERE si.[object_id] = OBJECT_ID(ei.[xSchema] + '.' + ei.[xTableName]) 
                      AND si.[name] = ei.[xIndexName])
      AND ei.IndexScript <> 'CREATE ' + 
                            CASE WHEN i.[Unique] = 1 THEN 'UNIQUE ' ELSE '' END + 
                            CASE WHEN i.[Clustered] = 1 THEN '' ELSE 'NON' END + 'CLUSTERED ' +
                            CASE WHEN i.[ColumnStore] = 1 THEN 'COLUMNSTORE ' ELSE '' END + 
	                        'INDEX ' + i.[IndexName] + ' ON ' + i.[Schema] + '.' + i.[TableName] + 
                            CASE WHEN i.[ColumnStore] = 0 THEN ' (' + i.[IndexColumns] + ')' + CASE WHEN RTRIM(ISNULL(i.[IncludeColumns], '')) <> '' THEN ' INCLUDE (' + i.[IncludeColumns] + ')' ELSE '' END
                                 WHEN i.[ColumnStore] = 1 AND i.[Clustered] = 0 THEN ' (' + i.[IncludeColumns] + ')'
                                 ELSE '' END +
                            CASE WHEN RTRIM(ISNULL(i.[FilterExpression], '')) <> '' THEN ' WHERE ' + i.[FilterExpression] ELSE '' END +
                            CASE WHEN (i.[ColumnStore] = 0 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('NONE', 'ROW', 'PAGE'))
                                   OR (i.[ColumnStore] = 1 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('COLUMNSTORE', 'COLUMNSTORE_ARCHIVE'))
                                 THEN ' WITH (DATA_COMPRESSION=' + RTRIM(ISNULL(i.[CompressionType], '')) + ')'
                                 ELSE '' END

  RAISERROR('Detect Index Renames（检测索引重命名）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#IndexRenames') IS NOT NULL DROP TABLE #IndexRenames
  SELECT i.[Schema], i.[TableName], [NewName] = i.[IndexName], ei.[IsConstraint], IsUnique = i.[Unique], [OldName] = ei.[xIndexName]
    INTO #IndexRenames
    FROM #ExistingIndexes ei WITH (NOLOCK)
    JOIN #Indexes i WITH (NOLOCK) ON ei.[xSchema] = i.[Schema]
                                 AND ei.[xTableName] = i.[TableName]
                                 AND ei.[xIndexName] <> SchemaSmith.fn_StripBracketWrapping(i.[IndexName])
    WHERE NOT EXISTS (SELECT * FROM #Indexes i2 WITH (NOLOCK) WHERE i2.[Schema] = ei.[xSchema] AND i2.[TableName] = ei.[xTableName] AND SchemaSmith.fn_StripBracketWrapping(i2.[IndexName]) = ei.[xIndexName])
      AND INDEXPROPERTY(OBJECT_ID(ei.[xSchema] + '.' + ei.[xTableName]), SchemaSmith.fn_StripBracketWrapping(i.[IndexName]), 'IndexID') IS NULL
      AND EXISTS (SELECT * 
                    FROM sys.indexes si WITH (NOLOCK)
                    WHERE si.[object_id] = OBJECT_ID(ei.[xSchema] + '.' + ei.[xTableName]) 
                      AND si.[name] = ei.[xIndexName])
      AND REPLACE(ei.IndexScript, ei.[xIndexName], 'IndexName') = 'CREATE ' + 
                                                                  CASE WHEN i.[Unique] = 1 OR i.[PrimaryKey] = 1 THEN 'UNIQUE ' ELSE '' END + 
                                                                  CASE WHEN i.[Clustered] = 1 THEN '' ELSE 'NON' END + 'CLUSTERED ' +
                                                                  CASE WHEN i.[ColumnStore] = 1 THEN 'COLUMNSTORE ' ELSE '' END + 
	                                                              'INDEX [IndexName] ON ' + i.[Schema] + '.' + i.[TableName] + 
                                                                  CASE WHEN i.[ColumnStore] = 0 THEN ' (' + i.[IndexColumns] + ')' + CASE WHEN RTRIM(ISNULL(i.[IncludeColumns], '')) <> '' THEN ' INCLUDE (' + i.[IncludeColumns] + ')' ELSE '' END
                                                                       WHEN i.[ColumnStore] = 1 AND i.[Clustered] = 0 THEN ' (' + i.[IncludeColumns] + ')'
                                                                       ELSE '' END +
                                                                  CASE WHEN RTRIM(ISNULL(i.[FilterExpression], '')) <> '' THEN ' WHERE ' + i.[FilterExpression] ELSE '' END +
                                                                  CASE WHEN (i.[ColumnStore] = 0 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('NONE', 'ROW', 'PAGE'))
                                                                         OR (i.[ColumnStore] = 1 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('COLUMNSTORE', 'COLUMNSTORE_ARCHIVE'))
                                                                       THEN ' WITH (DATA_COMPRESSION=' + RTRIM(ISNULL(i.[CompressionType], '')) + ')'
                                                                       ELSE '' END

  -- 从重命名列表中移除重复项
  SELECT MAX([NewName]) AS ValidNewName, [OldName] AS [OriginalName]
    INTO #IndexRenameDedupe
    FROM #IndexRenames ir WITH (NOLOCK)
    GROUP BY [OldName]  
  DELETE FROM #IndexRenames WHERE EXISTS (SELECT * FROM #IndexRenameDedupe dd WITH (NOLOCK) WHERE [OriginalName] = [OldName] AND [ValidNewName] <> [NewName])
  
  RAISERROR('Handle Renamed Indexes And Unique Constraints（处理重命名的索引和唯一约束）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Renaming ' + [OldName] + ' to ' + [NewName] + ' ON ' + ir.[Schema] + '.' + ir.[TableName] + '（重命名）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             CASE WHEN IsConstraint = 1
                                                                  THEN CASE WHEN OBJECT_ID(ir.[Schema] + '.' + ir.[NewName]) IS NULL
                                                                            THEN 'EXEC sp_rename N''' + SchemaSmith.fn_StripBracketWrapping(ir.[Schema]) + '.' + ir.[OldName] + ''', N''' + SchemaSmith.fn_StripBracketWrapping(ir.[NewName]) + ''', N''OBJECT'';'
                                                                            ELSE 'IF EXISTS (SELECT * FROM sys.objects WHERE [name] = ''' + ir.[OldName] + ''' AND parent_object_id = OBJECT_ID(''' + ir.[Schema] + '.' + ir.[TableName] + ''')) ' +
                                                                                 'ALTER TABLE ' + ir.[Schema] + '.' + ir.[TableName] + ' DROP CONSTRAINT [' + ir.[OldName] + '];'
                                                                            END
                                                                  ELSE CASE WHEN INDEXPROPERTY(OBJECT_ID(ir.[Schema] + '.' + ir.[TableName]), SchemaSmith.fn_StripBracketWrapping(ir.[NewName]), 'IndexID') IS NULL
                                                                            THEN 'EXEC sp_rename N''' + SchemaSmith.fn_StripBracketWrapping(ir.[Schema]) + '.' + SchemaSmith.fn_StripBracketWrapping(ir.[TableName]) + '.' + ir.[OldName] + ''', N''' + SchemaSmith.fn_StripBracketWrapping(ir.[NewName]) + ''', N''INDEX'';'
                                                                            ELSE 'IF EXISTS (SELECT * FROM sys.indexes WHERE [name] = ''' + SchemaSmith.fn_StripBracketWrapping(ir.[OldName]) + ''' AND [object_id] = OBJECT_ID(''' + ir.[Schema] + '.' + ir.[TableName] + ''')) ' +
                                                                                 'DROP INDEX [' + ir.[OldName] + '] ON ' + ir.[Schema] + '.' + ir.[TableName] + ';'
                                                                            END
                                                                  END AS NVARCHAR(MAX))
                            FROM #IndexRenames ir WITH (NOLOCK)
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Collect Existing XML Index Definitions（收集现有 XML 索引定义）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#ExistingXmlIndexes') IS NOT NULL DROP TABLE #ExistingXmlIndexes
  SELECT xSchema = t.[Schema], [xTableName] = t.[Name], [xIndexName] = CAST(i.[Name] COLLATE DATABASE_DEFAULT AS NVARCHAR(500)),
         IndexScript = 'CREATE ' + CASE WHEN i.xml_index_type = 0 THEN 'PRIMARY ' ELSE '' END + 
                       'XML INDEX [' + i.[name] COLLATE DATABASE_DEFAULT + '] ON [' + OBJECT_SCHEMA_NAME(i.[object_id]) + '].[' + OBJECT_NAME(i.[object_id]) + '] ' + 
                       '([' + COL_NAME(i.[Object_id], ic.column_id) + '])' + 
                       CASE WHEN i.xml_index_type = 1 
                            THEN ' USING XML INDEX [' + (SELECT [Name] FROM sys.xml_indexes i2 WHERE i2.[object_id] = i.[object_id] AND i2.index_id = i.using_xml_index_id) COLLATE DATABASE_DEFAULT + '] ' + 
                                 'FOR ' + i.secondary_type_desc COLLATE DATABASE_DEFAULT 
                            ELSE '' END
    INTO #ExistingXmlIndexes
    FROM #Tables t WITH (NOLOCK)
    JOIN sys.xml_indexes i ON i.[object_id] = OBJECT_ID(t.[Schema] + '.' + t.[Name])
    JOIN sys.index_columns ic ON i.[object_id] = ic.[object_id] AND i.index_id = ic.index_id
    WHERE t.NewTable = 0

  RAISERROR('Detect Xml Index Changes（检测 XML 索引变更）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#XmlIndexChanges') IS NOT NULL DROP TABLE #XmlIndexChanges
  SELECT i.[Schema], i.[TableName], i.[IndexName]
    INTO #XmlIndexChanges
    FROM #ExistingXmlIndexes ei WITH (NOLOCK)
    JOIN #XmlIndexes i WITH (NOLOCK) ON ei.[xSchema] = i.[Schema]
                                    AND ei.[xTableName] = i.[TableName]
                                    AND ei.[xIndexName] = SchemaSmith.fn_StripBracketWrapping(i.[IndexName])
    WHERE EXISTS (SELECT * 
                    FROM sys.xml_indexes si WITH (NOLOCK)
                    WHERE si.[object_id] = OBJECT_ID(ei.[xSchema] + '.' + ei.[xTableName]) 
                      AND si.[name] = ei.[xIndexName])
      AND ei.IndexScript <> 'CREATE ' + CASE WHEN i.IsPrimary = 1 THEN 'PRIMARY ' ELSE '' END + 
                            'XML INDEX ' + i.[IndexName] COLLATE DATABASE_DEFAULT + ' ON ' + i.[Schema] + '.' + i.[TableName] + ' (' + i.[Column] + ')' + 
                            CASE WHEN i.IsPrimary = 0
                                 THEN ' USING XML INDEX ' + i.PrimaryIndex + ' FOR ' + i.SecondaryIndexType
                                 ELSE '' END
  
  RAISERROR('Detect Xml Index Renames（检测 XML 索引重命名）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#XmlIndexRenames') IS NOT NULL DROP TABLE #XmlIndexRenames
  SELECT i.[Schema], i.[TableName], [NewName] = i.[IndexName], [OldName] = ei.[xIndexName]
    INTO #XmlIndexRenames
    FROM #ExistingXmlIndexes ei WITH (NOLOCK)
    JOIN #XmlIndexes i WITH (NOLOCK) ON ei.[xSchema] = i.[Schema]
                                    AND ei.[xTableName] = i.[TableName]
                                    AND ei.[xIndexName] <> SchemaSmith.fn_StripBracketWrapping(i.[IndexName])
    WHERE NOT EXISTS (SELECT * FROM #XmlIndexes i2 WITH (NOLOCK) WHERE i2.[Schema] = ei.[xSchema] AND i2.[TableName] = ei.[xTableName] AND SchemaSmith.fn_StripBracketWrapping(i2.[IndexName]) = ei.[xIndexName])
      AND INDEXPROPERTY(OBJECT_ID(ei.[xSchema] + '.' + ei.[xTableName]), SchemaSmith.fn_StripBracketWrapping(i.[IndexName]), 'IndexID') IS NULL
      AND EXISTS (SELECT * 
                    FROM sys.xml_indexes si WITH (NOLOCK)
                    WHERE si.[object_id] = OBJECT_ID(ei.[xSchema] + '.' + ei.[xTableName]) 
                      AND si.[name] = ei.[xIndexName])
      AND REPLACE(ei.IndexScript, ei.[xIndexName], 'IndexName') = 'CREATE ' + CASE WHEN i.IsPrimary = 1 THEN 'PRIMARY ' ELSE '' END + 
                                                                  'XML INDEX [IndexName] ON ' + i.[Schema] + '.' + i.[TableName] + ' (' + i.[Column] + ')' + 
                                                                  CASE WHEN i.IsPrimary = 0
                                                                       THEN ' USING XML INDEX ' + i.PrimaryIndex + ' FOR ' + i.SecondaryIndexType
                                                                       ELSE '' END

  RAISERROR('Handle Renamed Xml Indexes（处理重命名的 XML 索引）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Renaming ' + [OldName] + ' to ' + [NewName] + ' ON ' + ir.[Schema] + '.' + ir.[TableName] + '（重命名）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             CASE WHEN INDEXPROPERTY(OBJECT_ID(ir.[Schema] + '.' + ir.[TableName]), SchemaSmith.fn_StripBracketWrapping(ir.[NewName]), 'IndexID') IS NULL
                                                                  THEN 'EXEC sp_rename N''' + SchemaSmith.fn_StripBracketWrapping(ir.[Schema]) + '.' + SchemaSmith.fn_StripBracketWrapping(ir.[TableName]) + '.' + ir.[OldName] + ''', N''' + SchemaSmith.fn_StripBracketWrapping(ir.[NewName]) + ''', N''INDEX'';'
                                                                  ELSE 'IF EXISTS (SELECT * FROM sys.indexes WHERE [name] = ''' + SchemaSmith.fn_StripBracketWrapping(ir.[OldName]) + ''' AND [object_id] = OBJECT_ID(''' + ir.[Schema] + '.' + ir.[TableName] + ''')) ' +
                                                                       'DROP INDEX [' + ir.[OldName] + '] ON ' + ir.[Schema] + '.' + ir.[TableName] + ';'
                                                                  END AS NVARCHAR(MAX))
                            FROM #XmlIndexRenames ir WITH (NOLOCK)
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Identify unknown and modified indexes to drop（识别需要删除的未知或已修改索引）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#IndexesToDrop') IS NOT NULL DROP TABLE #IndexesToDrop
  SELECT [Schema] = CAST([Schema] AS NVARCHAR(500)), [TableName] = CAST([TableName] AS NVARCHAR(500)), 
         [IndexName] = CAST(SchemaSmith.fn_StripBracketWrapping([IndexName]) AS NVARCHAR(500)), [IsConstraint], [IsUnique] = i.[is_unique], 
         [IsClustered] = CAST(CASE WHEN i.[type_desc] = 'CLUSTERED' THEN 1 ELSE 0 END AS BIT)
    INTO #IndexesToDrop
    FROM #IndexesRemovedFromProduct ir WITH (NOLOCK)
    JOIN sys.indexes i WITH (NOLOCK) ON i.[object_id] = OBJECT_ID([Schema] + '.' + [TableName]) AND i.[Name] = SchemaSmith.fn_StripBracketWrapping([IndexName])
  UNION
  SELECT [Schema], [TableName], SchemaSmith.fn_StripBracketWrapping([IndexName]), [IsConstraint], [IsUnique], [IsClustered]
    FROM #IndexesToDropForColumnChanges WITH (NOLOCK)
  UNION
  SELECT [xSchema], [xTableName], [xIndexName], [IsConstraint], [IsUnique], [IsClustered]
    FROM #ExistingIndexes ei WITH (NOLOCK)
    WHERE @DropUnknownIndexes = 1
      AND NOT EXISTS (SELECT * FROM #Indexes i WITH (NOLOCK) WHERE i.[Schema] = ei.[xSchema] AND i.[TableName] = ei.[xTableName] AND SchemaSmith.fn_StripBracketWrapping(i.[IndexName]) = ei.[xIndexName])
  UNION
  SELECT [Schema], [TableName], SchemaSmith.fn_StripBracketWrapping([IndexName]), [IsConstraint], [IsUnique], [IsClustered]
    FROM #IndexChanges WITH (NOLOCK)
  UNION
  SELECT [xSchema], [xTableName], [xIndexName], [IsConstraint] = 0, [IsUnique] = 0, [IsClustered] = 0
    FROM #ExistingXmlIndexes ei WITH (NOLOCK)
    WHERE @DropUnknownIndexes = 1
      AND NOT EXISTS (SELECT * FROM #XmlIndexes i WITH (NOLOCK) WHERE i.[Schema] = ei.[xSchema] AND i.[TableName] = ei.[xTableName] AND SchemaSmith.fn_StripBracketWrapping(i.[IndexName]) = ei.[xIndexName])
  UNION
  SELECT [Schema], [TableName], SchemaSmith.fn_StripBracketWrapping([IndexName]), [IsConstraint] = 0, [IsUnique] = 0, [IsClustered] = 0
    FROM #XmlIndexChanges WITH (NOLOCK)
  
  -- 如果删除聚集主键，需要删除所有 XML 索引
  INSERT #IndexesToDrop ([Schema], [TableName], [IndexName], [IsConstraint], [IsUnique], [IsClustered])
    SELECT [xSchema], [xTableName], [xIndexName], [IsConstraint] = 0, [IsUnique] = 0, [IsClustered] = 0
      FROM #ExistingXmlIndexes ei WITH (NOLOCK)
      WHERE EXISTS (SELECT * FROM #IndexesToDrop id WITH (NOLOCK) WHERE [xSchema] = [Schema] AND [xTableName] = [TableName] AND id.[IsClustered] = 1)
        AND NOT EXISTS (SELECT * FROM #IndexesToDrop id WITH (NOLOCK) WHERE [xSchema] = [Schema] AND [xTableName] = [TableName] AND [xIndexName] = [IndexName])

  RAISERROR('Drop Referencing Foreign Keys When Dropping Unique Indexes（在删除唯一索引时删除引用外键）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STUFF((SELECT CHAR(13) + CHAR(10) + CAST('RAISERROR(''  Dropping foreign Key ' + OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id) + '.' + fk.[name] + '（删除外键）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                                             'IF EXISTS (SELECT * FROM sys.foreign_keys WHERE [name] = ''' + fk.[name] + ''' AND parent_object_id = ' + CONVERT(VARCHAR(20), fk.parent_object_id) + ') ' +
                                                             'ALTER TABLE [' + OBJECT_SCHEMA_NAME(fk.parent_object_id) + '].[' + OBJECT_NAME(fk.parent_object_id) + '] DROP CONSTRAINT [' + fk.[name] + '];' AS NVARCHAR(MAX))
                            FROM #IndexesToDrop di WITH (NOLOCK)
                            JOIN sys.foreign_keys fk WITH (NOLOCK) ON fk.referenced_object_id = OBJECT_ID(di.[Schema] + '.' + di.[TableName])
                            WHERE IsConstraint = 1 OR IsUnique = 1
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Drop FullText Indexes Referencing Unique Indexes That Will Be Dropped（删除引用将被删除的唯一索引的全文索引）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping fulltext index on ' + ef.[Schema] + '.' + ef.[TableName] + '（删除全文索引）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'DROP FULLTEXT INDEX ON ' + ef.[Schema] + '.' + ef.[TableName] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #IndexesToDrop id WITH (NOLOCK)
    JOIN #ExistingFullTextIndexes ef WITH (NOLOCK) ON id.[Schema] = ef.[Schema]
                                                  AND id.[TableName] = ef.[TableName]
                                                  AND id.[IndexName] = SchemaSmith.fn_StripBracketWrapping(ef.[KeyIndex])
    JOIN sys.fulltext_indexes fi WITH (NOLOCK) ON fi.[object_id] = OBJECT_ID(ef.[Schema] + '.' + ef.[TableName])
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Drop Unknown and Modified Indexes（删除未知和已修改的索引）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping ' + CASE WHEN IsConstraint = 1 THEN 'constraint' ELSE 'index' END + ' ' + di.[Schema] + '.' + di.[TableName] + '.' + di.[IndexName] + '（删除）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  CASE WHEN IsConstraint = 1
                                       THEN 'ALTER TABLE ' + di.[Schema] + '.' + di.[TableName] + ' DROP CONSTRAINT IF EXISTS [' + di.[IndexName] + '];'
                                       ELSE 'DROP INDEX IF EXISTS [' + di.[IndexName] + '] ON ' + di.[Schema] + '.' + di.[TableName] + ';'
                                       END AS NVARCHAR(MAX)), CHAR(13) + CHAR(10)) WITHIN GROUP (ORDER BY CASE WHEN [IsClustered] = 0 THEN 0 ELSE 1 END)
    FROM #IndexesToDrop di WITH (NOLOCK)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  IF @UpdateFillFactor = 1
  BEGIN
    RAISERROR('Fixup Modified Fillfactors（修正已修改的填充因子）', 10, 1) WITH NOWAIT
    SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Fixup ' + CASE WHEN IsConstraint = 1 THEN 'constraint' ELSE 'index' END + ' fillfactor in ' + i.[Schema] + '.' + i.[TableName] + '.' + i.[IndexName] + '（修正填充因子）'', 10, 1) WITH NOWAIT; ' + 
                                    'ALTER INDEX ' + i.[IndexName] + ' ON ' + i.[Schema] + '.' + i.[TableName] + ' REBUILD WITH (FILLFACTOR = ' + CONVERT(NVARCHAR(5), i.[FillFactor]) + ', SORT_IN_TEMPDB = ON);' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
      FROM #ExistingIndexes ei WITH (NOLOCK)
      JOIN #Indexes i WITH (NOLOCK) ON ei.[xSchema] = i.[Schema]
                                   AND ei.[xTableName] = i.[TableName]
                                   AND ei.[xIndexName] = SchemaSmith.fn_StripBracketWrapping(i.[IndexName])
      WHERE ei.[FillFactor] <> i.[FillFactor]
        AND INDEXPROPERTY(OBJECT_ID(i.[Schema] + '.' + i.[TableName]), ei.[xIndexName], 'IndexID') IS NOT NULL
    IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  END
  
  RAISERROR('Identify Statistics To Drop Based On Column Changes（根据列变更识别待删除统计信息）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#StatisticsToDropForChanges') IS NOT NULL DROP TABLE #StatisticsToDropForChanges
  SELECT DISTINCT cc.[Schema], cc.[TableName], [StatName] = i.[name]
    INTO #StatisticsToDropForChanges
    FROM sys.stats i WITH (NOLOCK) 
    JOIN #ColumnChanges cc WITH (NOLOCK) ON i.[object_id] = OBJECT_ID(cc.[Schema] + '.' + cc.[TableName]) 
    LEFT JOIN sys.stats_columns ic WITH (NOLOCK) ON ic.[object_id] = i.[object_id]
                                                AND ic.[stats_id] = i.[stats_id]
                                                AND COL_NAME(ic.[object_id], ic.column_id) = SchemaSmith.fn_StripBracketWrapping(cc.ColumnName)
    WHERE ic.column_id IS NOT NULL
       OR i.filter_definition LIKE '%' + SchemaSmith.fn_StripBracketWrapping(cc.ColumnName) + '%'
  
  RAISERROR('Drop Statistics Referencing Modified Columns（删除引用已修改列的统计信息）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping statistic ' + id.[Schema] + '.' + id.[TableName] + '.[' + [StatName] + ']（删除统计信息）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'DROP STATISTICS ' + id.[Schema] + '.' + id.[TableName] + '.[' + [StatName] + '];' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #StatisticsToDropForChanges id WITH (NOLOCK)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Identify Foreign Keys To Drop Based On Column Changes（根据列变更识别待删除外键）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#FKsToDropForChanges') IS NOT NULL DROP TABLE #FKsToDropForChanges
  SELECT DISTINCT cc.[Schema], cc.[TableName], FKName = fk.[name]
    INTO #FKsToDropForChanges
    FROM sys.foreign_key_columns fc WITH (NOLOCK)
    LEFT JOIN sys.foreign_keys fk WITH (NOLOCK) ON fk.object_id = fc.constraint_object_id
    JOIN #ColumnChanges cc WITH (NOLOCK) ON (OBJECT_ID(cc.[Schema] + '.' + cc.[TableName]) = fk.parent_object_id
                                         AND SchemaSmith.fn_StripBracketWrapping(cc.ColumnName) = COL_NAME(fc.[parent_object_id], fc.parent_column_id))
                                         OR (OBJECT_ID(cc.[Schema] + '.' + cc.[TableName]) = fk.referenced_object_id
                                         AND SchemaSmith.fn_StripBracketWrapping(cc.ColumnName) = COL_NAME(fc.[referenced_object_id], fc.referenced_column_id))
  
  RAISERROR('Drop Foreign Keys Referencing Modified Columns（删除引用已修改列的外键）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping foreign Key ' + df.[Schema] + '.' + df.[TableName] + '.' + df.[FKName] + '（删除外键）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + df.[Schema] + '.' + df.[TableName] + ' DROP CONSTRAINT IF EXISTS ' + df.[FKName] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #FKsToDropForChanges df WITH (NOLOCK)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Identify Defaults To Drop Based On Column Changes（根据列变更识别待删除默认值）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#DefaultsToDropForChanges') IS NOT NULL DROP TABLE #DefaultsToDropForChanges
  SELECT cc.[Schema], cc.[TableName], DefaultName = dc.[name]
    INTO #DefaultsToDropForChanges
    FROM sys.default_constraints dc WITH (NOLOCK)
    JOIN #ColumnChanges cc WITH (NOLOCK) ON dc.[parent_object_id] = OBJECT_ID(cc.[Schema] + '.' + cc.[TableName]) 
                                        AND COL_NAME(dc.parent_object_id, dc.parent_column_id) = SchemaSmith.fn_StripBracketWrapping(cc.ColumnName)
  
  RAISERROR('Drop Defaults Referencing Modified Columns（删除引用已修改列的默认值）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping default ' + dd.[Schema] + '.' + dd.[TableName] + '.' + dd.[DefaultName] + '（删除默认值）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + dd.[Schema] + '.' + dd.[TableName] + ' DROP CONSTRAINT IF EXISTS ' + dd.[DefaultName] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #DefaultsToDropForChanges dd WITH (NOLOCK)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Identify Check Constraints To Drop Based On Column Changes（根据列变更识别待删除检查约束）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#ChecksToDropForChanges') IS NOT NULL DROP TABLE #ChecksToDropForChanges
  SELECT cc.[Schema], cc.[TableName], CheckName = ck.[name]
    INTO #ChecksToDropForChanges
    FROM sys.check_constraints ck WITH (NOLOCK)
    JOIN #ColumnChanges cc WITH (NOLOCK) ON ck.[parent_object_id] = OBJECT_ID(cc.[Schema] + '.' + cc.[TableName]) 
                                        AND ((ck.parent_column_id <> 0 AND COL_NAME(ck.parent_object_id, ck.parent_column_id) = SchemaSmith.fn_StripBracketWrapping(cc.ColumnName))
                                          OR (ck.parent_column_id = 0 AND ck.[definition] LIKE '%' + SchemaSmith.fn_StripBracketWrapping(cc.ColumnName) + '%'))
  
  RAISERROR('Drop Check Constraints Referencing Modified Columns（删除引用已修改列的检查约束）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping check constraint ' + fc.[Schema] + '.' + fc.[TableName] + '.' + fc.CheckName + '（删除检查约束）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + fc.[Schema] + '.' + fc.[TableName] + ' DROP CONSTRAINT IF EXISTS ' + fc.CheckName + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #ChecksToDropForChanges fc WITH (NOLOCK)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Drop Modified Computed Columns（删除已修改的计算列）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping columns from ' + T.[Schema] + '.' + T.[Name] + ' (' + MessageColumns + ')（删除列）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + T.[Schema] + '.' + T.[Name] + ' DROP ' + ScriptColumns + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM (SELECT T.[Schema], T.[Name], 
                 ScriptColumns = (SELECT STRING_AGG(CAST('COLUMN ' + [ColumnName] AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY cc.[ColumnName]) FROM #ColumnChanges cc WITH (NOLOCK) WHERE cc.[Schema] = T.[Schema] AND cc.[TableName] = T.[Name] AND cc.MustDropAndRecreate = 1),
                 MessageColumns = (SELECT STRING_AGG(CAST([ColumnName] AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY cc.[ColumnName]) FROM #ColumnChanges cc WITH (NOLOCK) WHERE cc.[Schema] = T.[Schema] AND cc.[TableName] = T.[Name] AND cc.MustDropAndRecreate = 1)
            FROM #Tables T WITH (NOLOCK)
            WHERE NewTable = 0
              AND EXISTS (SELECT * FROM #ColumnChanges cc WITH (NOLOCK) WHERE cc.[Schema] = T.[Schema] AND cc.[TableName] = T.[Name] AND cc.MustDropAndRecreate = 1)) T
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Drop Columns No Longer Part of The Product Definition（删除不再属于产品定义的列）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping columns from ' + T.[Schema] + '.' + T.[Name] + ' (' + MessageColumns + ')（删除列）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + T.[Schema] + '.' + T.[Name] + ' DROP ' + ScriptColumns + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM (SELECT T.[Schema], T.[Name],
                 ScriptColumns = (SELECT STRING_AGG(CAST('COLUMN ' + [ColumnName] AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY [ColumnName]) FROM #ColumnChanges cc WITH (NOLOCK) WHERE cc.[Schema] = T.[Schema] AND cc.[TableName] = T.[Name] AND cc.DropOnly = 1),
                 MessageColumns = (SELECT STRING_AGG(CAST([ColumnName] AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY [ColumnName]) FROM #ColumnChanges cc WITH (NOLOCK) WHERE cc.[Schema] = T.[Schema] AND cc.[TableName] = T.[Name] AND cc.DropOnly = 1)
            FROM #Tables T WITH (NOLOCK)
            WHERE NewTable = 0
              AND EXISTS (SELECT * FROM #ColumnChanges cc WITH (NOLOCK) WHERE cc.[Schema] = T.[Schema] AND cc.[TableName] = T.[Name] AND cc.DropOnly = 1)) T
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  UPDATE c
    SET NewColumn = 1
    FROM #Columns c
    WHERE EXISTS (SELECT * FROM #ColumnChanges cc WITH (NOLOCK) WHERE cc.[Schema] = c.[Schema] AND cc.[TableName] = c.[TableName] and cc.ColumnName = c.ColumnName AND cc.MustDropAndRecreate = 1)
  
  RAISERROR('Add New Tables（新增表）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Adding new table ' + T.[Schema] + '.' + T.[Name] + '（新增表）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'CREATE TABLE ' + T.[Schema] + '.' + T.[Name] + ' (' + ScriptColumns + ')' + 
                                  CASE WHEN ISNULL(t.[CompressionType], 'NONE') IN ('NONE', 'ROW', 'PAGE') THEN ' WITH (DATA_COMPRESSION=' + ISNULL(t.[CompressionType], 'NONE') + ')' ELSE '' END + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM (SELECT T.[Schema], T.[Name], t.[CompressionType],
                 ScriptColumns = (SELECT STRING_AGG(CAST([ColumnScript] AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY c.[ColumnName]) FROM #Columns C WITH (NOLOCK) WHERE C.[Schema] = T.[Schema] AND C.[TableName] = T.[Name])
            FROM #Tables T WITH (NOLOCK)
            WHERE NewTable = 1
              AND EXISTS (SELECT * FROM #Columns C WITH (NOLOCK) WHERE C.[Schema] = T.[Schema] AND C.[TableName] = T.[Name])) T
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Add missing ProductName extended property to tables（为表补充 ProductName 扩展属性）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('EXEC sp_addextendedproperty @name = N''ProductName'', @value = ''' + @ProductName + ''', ' +
                                                              '@level0type = N''Schema'', @level0name = ''' + SchemaSmith.fn_StripBracketWrapping(t.[Schema]) + ''', ' +
                                                              '@level1type = N''Table'', @level1name = ''' + SchemaSmith.fn_StripBracketWrapping(t.[Name]) + ''';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #Tables t WITH (NOLOCK)
    WHERE NOT EXISTS (SELECT * FROM #TableProperties tp WITH (NOLOCK) WHERE t.[Schema] = tp.[Schema] AND SchemaSmith.fn_StripBracketWrapping(t.[Name]) = tp.TableName AND tp.PropertyName = 'ProductName')
      AND OBJECT_ID(t.[Schema] + '.' + t.[Name]) IS NOT NULL  -- 且表实际存在
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Add New Physical Columns（新增物理列）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Adding ' + CAST(ColumnCount AS VARCHAR(20)) + ' new columns to ' + T.[Schema] + '.' + T.[Name] + '（新增列）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + T.[Schema] + '.' + T.[Name] + ' ADD ' + ColumnScripts + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM (SELECT T.[Schema], T.[Name],
                 ColumnScripts = (SELECT STRING_AGG(CAST([ColumnScript] AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY c.[ColumnName]) FROM #Columns C WITH (NOLOCK) WHERE C.[Schema] = T.[Schema] AND C.[TableName] = T.[Name] AND c.NewColumn = 1 AND RTRIM(ISNULL([ComputedExpression], '')) = ''),
                 ColumnCount = (SELECT COUNT(*) FROM #Columns C WITH (NOLOCK) WHERE C.[Schema] = T.[Schema] AND C.[TableName] = T.[Name] AND c.NewColumn = 1 AND RTRIM(ISNULL([ComputedExpression], '')) = '')
            FROM #Tables T WITH (NOLOCK)
            WHERE NewTable = 0
              AND EXISTS (SELECT * FROM #Columns c WHERE C.[Schema] = T.[Schema] AND C.[TableName] = T.[Name] AND c.NewColumn = 1 AND RTRIM(ISNULL([ComputedExpression], '')) = '')) T
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Detect Default Changes（检测默认值变更）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#DefaultChanges') IS NOT NULL DROP TABLE #DefaultChanges
  SELECT C.[Schema], C.[TableName], C.[ColumnName],
         [DefaultName] = (SELECT [Name] 
                            FROM sys.default_constraints dc WITH (NOLOCK)
                            WHERE dc.parent_object_id = OBJECT_ID(c.[Schema] + '.' + c.[TableName]) 
                              AND COL_NAME(dc.parent_object_id, dc.parent_column_id) = SchemaSmith.fn_StripBracketWrapping(C.[ColumnName]))
    INTO #DefaultChanges
    FROM #Tables T WITH (NOLOCK)
    JOIN #Columns c WITH (NOLOCK) ON C.[Schema] = T.[Schema] 
                                 AND C.[TableName] = T.[Name]
                                 AND C.[NewColumn] = 0
    JOIN INFORMATION_SCHEMA.COLUMNS ic ON ic.TABLE_SCHEMA = SchemaSmith.fn_StripBracketWrapping(C.[Schema])
                                      AND ic.TABLE_NAME = SchemaSmith.fn_StripBracketWrapping(C.[TableName])
                                      AND ic.COLUMN_NAME = SchemaSmith.fn_StripBracketWrapping(C.[ColumnName])
    WHERE t.NewTable = 0
      AND SchemaSmith.fn_StripParenWrapping(ic.COLUMN_DEFAULT) <> ISNULL(c.[Default], 'NULL')
  
  RAISERROR('Drop Modified Defaults（删除已修改默认值）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping default ' + dc.[Schema] + '.' + dc.[TableName] + '.' + dc.[DefaultName] + '（删除默认值）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + dc.[Schema] + '.' + dc.[TableName] + ' DROP CONSTRAINT IF EXISTS ' + dc.[DefaultName] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #DefaultChanges dc WITH (NOLOCK)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Collect Existing Foreign Keys（收集现有外键）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#ExistingFKs') IS NOT NULL DROP TABLE #ExistingFKs
  SELECT t.[Schema], [TableName] = t.[Name],
         FKName = fk.[Name],
         FKScript = '(' + (SELECT STRING_AGG(CAST('[' + COL_NAME(fc.[parent_object_id], fc.parent_column_id) + ']' AS NVARCHAR(MAX)), ',') WITHIN GROUP (ORDER BY fc.constraint_column_id)
                             FROM sys.foreign_key_columns fc WITH (NOLOCK)
                             WHERE fk.[object_id] = fc.[constraint_object_id]) + ')' +
                    ' REFERENCES [' + OBJECT_SCHEMA_NAME(referenced_object_id) + '].[' + OBJECT_NAME(referenced_object_id) + '] ' +
                    '(' + (SELECT STRING_AGG(CAST('[' + COL_NAME(fc.[referenced_object_id], fc.referenced_column_id) + ']' AS NVARCHAR(MAX)), ',') WITHIN GROUP (ORDER BY fc.constraint_column_id)
                             FROM sys.foreign_key_columns fc WITH (NOLOCK)
                             WHERE fk.[object_id] = fc.[constraint_object_id]) + ')' +
                    ' ON DELETE ' + REPLACE(fk.update_referential_action_desc, '_', ' ') COLLATE DATABASE_DEFAULT +
                    ' ON UPDATE ' + REPLACE(fk.delete_referential_action_desc, '_', ' ') COLLATE DATABASE_DEFAULT
    INTO #ExistingFKs
    FROM #Tables t WITH (NOLOCK)
    JOIN sys.foreign_keys fk WITH (NOLOCK) ON fk.parent_object_id = OBJECT_ID(t.[Schema] + '.' + t.[Name]) 
    WHERE t.NewTable = 0

  RAISERROR('Detect Foreign Key Changes（检测外键变更）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#FKChanges') IS NOT NULL DROP TABLE #FKChanges
  SELECT ek.[Schema], ek.[TableName], ek.[FKName]
    INTO #FKChanges
    FROM #ExistingFKs ek WITH (NOLOCK)
    JOIN #ForeignKeys fk WITH (NOLOCK) ON ek.[TableName] = fk.[TableName]
                                      AND ek.[Schema] = fk.[Schema]
                                      AND ek.[FKName] = SchemaSmith.fn_StripBracketWrapping(fk.[KeyName])
    WHERE ek.FKScript <> '(' + [Columns] + ') REFERENCES ' + [RelatedTableSchema] + '.' + [RelatedTable] + ' (' + [RelatedColumns] + ')' +
                         ' ON DELETE ' + [DeleteAction] +
                         ' ON UPDATE ' + [UpdateAction]
  
  RAISERROR('Drop Modified Foreign Keys（删除已修改外键）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping Foreign Key ' + fc.[Schema] + '.' + fc.[TableName] + '.' + fc.[FKName] + '（删除外键）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + fc.[Schema] + '.' + fc.[TableName] + ' DROP CONSTRAINT IF EXISTS ' + fc.[FKName] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #FKChanges fc WITH (NOLOCK)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Collect Existing Statistics Definitions（收集现有统计信息定义）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#ExistingStats') IS NOT NULL DROP TABLE #ExistingStats
  SELECT t.[Schema], [TableName] = t.[Name], [StatsName] = si.[Name],
         StatisticScript = 'CREATE STATISTICS ' +
                           '[' + si.[Name] + '] ON ' + t.[Schema] + '.' + t.[Name] + ' (' +
                           (SELECT STRING_AGG(CAST('[' + COL_NAME(ic.[object_id], ic.column_id) + ']' AS NVARCHAR(MAX)), ',') WITHIN GROUP (ORDER BY ic.stats_column_id)
                              FROM sys.stats_columns ic WITH (NOLOCK)
                              WHERE si.[object_id] = ic.[object_id] AND si.stats_id = ic.stats_id) + ')' +
                           CASE WHEN si.has_filter = 1 THEN ' WHERE ' + SchemaSmith.fn_StripParenWrapping(si.filter_definition) ELSE '' END 
    INTO #ExistingStats 
    FROM #Tables t WITH (NOLOCK)
    JOIN sys.stats si WITH (NOLOCK) ON si.[object_id] = OBJECT_ID(t.[Schema] + '.' + t.[Name])
                                   AND auto_created = 0
                                   AND user_created = 1
                                   AND is_temporary = 0
                                   AND si.[Name] NOT LIKE 'stat[_]%'
                                   AND si.[Name] NOT LIKE 'hind[_]%'
    WHERE t.NewTable = 0
  
  RAISERROR('Detect Statistics Changes（检测统计信息变更）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#StatsChanges') IS NOT NULL DROP TABLE #StatsChanges
  SELECT s.[Schema], s.[TableName], s.[StatisticName]
    INTO #StatsChanges
    FROM #Statistics s WITH (NOLOCK)
    JOIN #ExistingStats es WITH (NOLOCK) ON s.[Schema] = es.[Schema]
                                        AND s.[TableName] = es.[TableName]
                                        AND SchemaSmith.fn_StripBracketWrapping(s.[StatisticName]) = es.[StatsName]
    WHERE es.StatisticScript <> 'CREATE STATISTICS ' + s.[StatisticName] + ' ON ' + s.[Schema] + '.' + s.[TableName] + ' (' + s.[Columns] + ')' +
                                CASE WHEN RTRIM(ISNULL(s.[FilterExpression], '')) <> '' THEN ' WHERE ' + s.[FilterExpression] ELSE '' END

  RAISERROR('Drop Modified Statistics（删除已修改统计信息）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping statistics ' + sc.[Schema] + '.' + sc.[TableName] + '.' + sc.[StatisticName] + '（删除统计信息）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'DROP STATISTICS ' + sc.[Schema] + '.' + sc.[TableName] + '.' + sc.[StatisticName] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #StatsChanges sc WITH (NOLOCK)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Collect Existing Check Constraints（收集现有检查约束）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#ExistingCheckConstraints') IS NOT NULL DROP TABLE #ExistingCheckConstraints
  SELECT t.[Schema], [TableName] = t.[Name], [CheckName] = ck.[name], 
         [CheckColumn] = CASE WHEN ck.parent_column_id <> 0 THEN COL_NAME(ck.parent_object_id, ck.parent_column_id) ELSE NULL END,
         [CheckDefinition] = SchemaSmith.fn_StripParenWrapping(ck.[definition])
    INTO #ExistingCheckConstraints
    FROM #Tables t WITH (NOLOCK)
    JOIN sys.check_constraints ck WITH (NOLOCK) ON ck.[parent_object_id] = OBJECT_ID(t.[Schema] + '.' + t.[Name])
  
  RAISERROR('Detect Column Level Check Constraint Changes（检测列级检查约束变更）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#CheckChanges') IS NOT NULL DROP TABLE #CheckChanges
  SELECT ec.[Schema], ec.[TableName], ec.[CheckName]
    INTO #CheckChanges
    FROM #ExistingCheckConstraints ec WITH (NOLOCK)
    JOIN #Columns c WITH (NOLOCK) ON ec.[Schema] = c.[Schema]
                                 AND ec.[TableName] = c.[TableName]
                                 AND ec.[CheckColumn] = SchemaSmith.fn_StripBracketWrapping(c.[ColumnName])
    WHERE ec.[CheckColumn] IS NOT NULL
      AND ec.[CheckDefinition] <> ISNULL(c.[CheckExpression], '')
      AND NOT EXISTS (SELECT * 
                        FROM #CheckConstraints cc WITH (NOLOCK) 
                        WHERE ec.[Schema] = cc.[Schema]
                          AND ec.[TableName] = cc.[TableName]
                          AND ec.[CheckName] = SchemaSmith.fn_StripBracketWrapping(cc.[ConstraintName]))

  RAISERROR('Detect Table Level Check Constraint Changes（检测表级检查约束变更）', 10, 1) WITH NOWAIT
  INSERT #CheckChanges ([Schema], [TableName], [CheckName])
    SELECT ec.[Schema], ec.[TableName], ec.[CheckName]
      FROM #ExistingCheckConstraints ec WITH (NOLOCK)
      JOIN #CheckConstraints cc WITH (NOLOCK) ON ec.[Schema] = cc.[Schema]
                                             AND ec.[TableName] = cc.[TableName]
                                             AND ec.[CheckName] = SchemaSmith.fn_StripBracketWrapping(cc.[ConstraintName])
      WHERE ec.[CheckDefinition] <> cc.[Expression]
  
  RAISERROR('Drop Modified Check Constraints（删除已修改检查约束）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping check constraint ' + cc.[Schema] + '.' + cc.[TableName] + '.' + cc.[CheckName] + '（删除检查约束）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + cc.[Schema] + '.' + cc.[TableName] + ' DROP CONSTRAINT IF EXISTS ' + cc.[CheckName] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #CheckChanges cc WITH (NOLOCK)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Alter Modified Columns（修改已变更的列）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Altering Column ' + cc.[Schema] + '.' + cc.[TableName] + '.' + cc.[ColumnName] + '（修改列）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + cc.[Schema] + '.' + cc.[TableName] + ' ALTER COLUMN ' + cc.[ColumnName] + ' ' + 
                                  CASE WHEN RTRIM([SpecialColumnScript]) <> '' THEN [SpecialColumnScript] ELSE [ColumnScript] END + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
        FROM #ColumnChanges cc WITH (NOLOCK)
        WHERE [MustDropAndRecreate] = 0
          AND [DropOnly] = 0
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Add New Computed Columns（新增计算列）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Adding ' + CAST(ColumnCount AS VARCHAR(20)) + ' new columns to ' + T.[Schema] + '.' + T.[Name] + '（新增计算列）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + T.[Schema] + '.' + T.[Name] + ' ADD ' + ScriptColumns + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM (SELECT T.[Schema], T.[Name],
                 ScriptColumns = (SELECT STRING_AGG(CAST(c.[ColumnScript] AS NVARCHAR(MAX)), ', ') WITHIN GROUP (ORDER BY c.[ColumnName]) FROM #Columns C WITH (NOLOCK) WHERE C.[Schema] = T.[Schema] AND C.[TableName] = T.[Name] AND c.NewColumn = 1 AND RTRIM(ISNULL([ComputedExpression], '')) <> ''),
                 ColumnCount = (SELECT COUNT(*) FROM #Columns C WITH (NOLOCK) WHERE C.[Schema] = T.[Schema] AND C.[TableName] = T.[Name] AND c.NewColumn = 1 AND RTRIM(ISNULL([ComputedExpression], '')) <> '')
            FROM #Tables T WITH (NOLOCK)
            WHERE NewTable = 0
              AND EXISTS (SELECT * FROM #Columns c WHERE C.[Schema] = T.[Schema] AND C.[TableName] = T.[Name] AND c.NewColumn = 1 AND RTRIM(ISNULL([ComputedExpression], '')) <> '')) T
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Identify Existing Clustered Index Conflicts（识别现有聚集索引冲突）', 10, 1) WITH NOWAIT
  IF OBJECT_ID('tempdb..#MissingClusteredIndexTables') IS NOT NULL DROP TABLE #MissingClusteredIndexTables
  SELECT DISTINCT i.[Schema], i.[TableName]
    INTO #MissingClusteredIndexTables
    FROM #Indexes i WITH (NOLOCK)
    WHERE i.[Clustered] = 1
      AND NOT EXISTS (SELECT * 
                        FROM sys.indexes si WITH (NOLOCK)
                        WHERE si.[object_id] = OBJECT_ID(i.[Schema] + '.' + i.[TableName]) 
                          AND si.[name] = SchemaSmith.fn_StripBracketWrapping(i.[IndexName]))
  
  RAISERROR('Drop Conflicting Clustered Index（删除冲突的聚集索引）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping ' + CASE WHEN si.is_primary_key = 1 OR si.is_unique_constraint = 1 THEN 'constraint' ELSE 'index' END + ' ' + mct.[Schema] + '.' + mct.[TableName] + '.' + si.[Name] + '（删除）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  CASE WHEN si.is_primary_key = 1 OR si.is_unique_constraint = 1
                                       THEN 'ALTER TABLE ' + mct.[Schema] + '.' + mct.[TableName] + ' DROP CONSTRAINT IF EXISTS [' + si.[Name] + '];'
                                       ELSE 'DROP INDEX IF EXISTS [' + si.[Name] + '] ON ' + mct.[Schema] + '.' + mct.[TableName] + ';'
                                       END AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #MissingClusteredIndexTables mct WITH (NOLOCK)
    JOIN sys.indexes si WITH (NOLOCK) ON si.[object_id] = OBJECT_ID(mct.[Schema] + '.' + mct.[TableName])
                                     AND si.[type] IN (1, 5)
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Add Missing Indexes（补充缺失索引）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Creating ' + CASE WHEN i.PrimaryKey = 1 OR i.UniqueConstraint = 1 THEN 'constraint' ELSE 'index' END + ' ' + i.[Schema] + '.' + i.[TableName] + '.' + i.[IndexName] + '（创建）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  CASE WHEN i.PrimaryKey = 1 OR i.UniqueConstraint = 1
                                       THEN 'ALTER TABLE ' + i.[Schema] + '.' + i.[TableName] + ' ADD CONSTRAINT ' + i.[IndexName] +
                                            CASE WHEN i.PrimaryKey = 1 THEN ' PRIMARY KEY ' WHEN i.UniqueConstraint = 1 THEN ' UNIQUE ' END +
                                            CASE WHEN i.[Clustered] =  1 THEN '' ELSE 'NON' END + 'CLUSTERED (' + i.IndexColumns + ')' +
                                            CASE WHEN RTRIM(ISNULL(i.[CompressionType], '')) IN ('NONE', 'ROW', 'PAGE')
                                                 THEN ' WITH (DATA_COMPRESSION=' + i.[CompressionType] + ')'
                                                 ELSE '' END
                                       ELSE 'CREATE ' + 
                                            CASE WHEN i.[Unique] = 1 THEN 'UNIQUE ' ELSE '' END +
                                            CASE WHEN i.[Clustered] =  1 THEN '' ELSE 'NON' END + 'CLUSTERED ' +
                                            CASE WHEN i.[ColumnStore] = 1 THEN 'COLUMNSTORE ' ELSE '' END +
                                            'INDEX ' + i.[IndexName] +
                                            ' ON ' + i.[Schema] + '.' + i.[TableName] +
                                            CASE WHEN i.[ColumnStore] = 0 THEN ' (' + i.[IndexColumns] + ')' + CASE WHEN RTRIM(ISNULL(i.[IncludeColumns], '')) <> '' THEN ' INCLUDE (' + i.[IncludeColumns] + ')' ELSE '' END
                                                 WHEN i.[ColumnStore] = 1 AND i.[Clustered] = 0 THEN ' (' + i.[IncludeColumns] + ')'
                                                 ELSE '' END +
                                            CASE WHEN RTRIM(ISNULL(i.[FilterExpression], '')) <> '' THEN ' WHERE ' + i.[FilterExpression] ELSE '' END +
					                        CASE WHEN (i.[ColumnStore] = 0 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('NONE', 'ROW', 'PAGE'))
                                                   OR (i.[ColumnStore] = 1 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('COLUMNSTORE', 'COLUMNSTORE_ARCHIVE'))
                                                   OR ISNULL(i.[FillFactor], 100) NOT IN (0, 100)
                                                 THEN ' WITH (' +
                                                      CASE WHEN (i.[ColumnStore] = 0 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('NONE', 'ROW', 'PAGE'))
                                                             OR (i.[ColumnStore] = 1 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('COLUMNSTORE', 'COLUMNSTORE_ARCHIVE'))
                                                           THEN 'DATA_COMPRESSION=' + i.[CompressionType] ELSE '' END +
                                                      CASE WHEN ISNULL(i.[FillFactor], 100) NOT IN (0, 100) 
                                                           THEN CASE WHEN (i.[ColumnStore] = 0 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('NONE', 'ROW', 'PAGE'))
                                                                       OR (i.[ColumnStore] = 1 AND RTRIM(ISNULL(i.[CompressionType], '')) IN ('COLUMNSTORE', 'COLUMNSTORE_ARCHIVE'))
                                                                     THEN ', ' ELSE '' END +
                                                                'FILLFACTOR = ' + CAST(i.[FillFactor] AS NVARCHAR(20)) 
                                                           ELSE '' END +
							                          ')'
                                                 ELSE '' END
                                       END + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10)) WITHIN GROUP (ORDER BY i.[Schema], i.[TableName], CASE WHEN i.[Clustered] =  1 THEN 0 ELSE 1 END, i.[IndexName])
    FROM #Indexes i WITH (NOLOCK)
    WHERE NOT EXISTS (SELECT * 
                        FROM sys.indexes si WITH (NOLOCK)
                        WHERE si.[object_id] = OBJECT_ID(i.[Schema] + '.' + i.[TableName]) 
                          AND si.[name] = SchemaSmith.fn_StripBracketWrapping(i.[IndexName]))    
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  

  RAISERROR('Add Missing Xml Indexes（补充缺失 XML 索引）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Creating index ' + i.[Schema] + '.' + i.[TableName] + '.' + i.[IndexName] + '（创建索引）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'CREATE ' + CASE WHEN i.IsPrimary = 1 THEN 'PRIMARY ' ELSE '' END + 
                                  'XML INDEX ' + i.[IndexName] COLLATE DATABASE_DEFAULT + ' ON ' + i.[Schema] + '.' + i.[TableName] + ' (' + i.[Column] + ')' + 
                                  CASE WHEN i.IsPrimary = 0 THEN ' USING XML INDEX ' + i.PrimaryIndex + ' FOR ' + i.SecondaryIndexType ELSE '' END +
                                  ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10)) WITHIN GROUP (ORDER BY i.[Schema], i.[TableName], CASE WHEN i.IsPrimary =  1 THEN 0 ELSE 1 END, i.[IndexName])
    FROM #XmlIndexes i WITH (NOLOCK)
    WHERE NOT EXISTS (SELECT * 
                        FROM sys.xml_indexes si WITH (NOLOCK)
                        WHERE si.[object_id] = OBJECT_ID(i.[Schema] + '.' + i.[TableName]) 
                          AND si.[name] = SchemaSmith.fn_StripBracketWrapping(i.[IndexName]))    
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Turn on Temporal Tracking for tables defined as temporal（为时态表开启时态跟踪）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Turn ON Temporal Tracking for ' + T.[Schema] + '.' + T.[Name] + '（开启时态跟踪）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + T.[Schema] + '.' + T.[Name] + ' ADD [ValidFrom] DATETIME2(7) GENERATED ALWAYS AS ROW START NOT NULL DEFAULT ''0001-01-01 00:00:00.0000000'', ' +
                                                                                      '[ValidTo] DATETIME2(7) GENERATED ALWAYS AS ROW END NOT NULL DEFAULT ''9999-12-31 23:59:59.9999999'', ' +
                                                                                      'PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo);' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + T.[Schema] + '.' + T.[Name] + ' SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = ' + T.[Schema] + '.[' + SchemaSmith.fn_StripBracketWrapping(T.[Name]) + '_Hist]));' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #Tables T WITH (NOLOCK)
    WHERE t.IsTemporal = 1
      AND OBJECTPROPERTY(OBJECT_ID([Schema] + '.' + [Name]), 'TableTemporalType') = 0
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Add missing ProductName extended property to indexes（为索引补充 ProductName 扩展属性）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('EXEC sp_addextendedproperty @name = N''ProductName'', @value = ''' + @ProductName + ''', ' +
                                                              '@level0type = N''Schema'', @level0name = ''' + SchemaSmith.fn_StripBracketWrapping(t.[Schema]) + ''', ' +
                                                              '@level1type = N''Table'', @level1name = ''' + SchemaSmith.fn_StripBracketWrapping(t.[Name]) + ''', ' +
                                                              '@level2type = N''Index'', @level2name = ''' + SchemaSmith.fn_StripBracketWrapping(i.IndexName) + ''';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #Indexes i WITH (NOLOCK)
    JOIN #Tables t WITH (NOLOCK) ON t.[Schema] = i.[Schema] AND t.[Name] = i.[TableName]
    WHERE INDEXPROPERTY(OBJECT_ID(t.[Schema] + '.' + t.[Name]), SchemaSmith.fn_StripBracketWrapping(i.IndexName), 'IndexID') IS NOT NULL
      AND NOT EXISTS (SELECT * FROM #IndexProperties ip WITH (NOLOCK) WHERE i.[Schema] = ip.[Schema] AND i.TableName = ip.TableName AND SchemaSmith.fn_StripBracketWrapping(i.IndexName) = ip.IndexName AND ip.PropertyName = 'ProductName')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Add missing ProductName extended property to xml indexes（为 XML 索引补充 ProductName 扩展属性）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('EXEC sp_addextendedproperty @name = N''ProductName'', @value = ''' + @ProductName + ''', ' +
                                                              '@level0type = N''Schema'', @level0name = ''' + SchemaSmith.fn_StripBracketWrapping(t.[Schema]) + ''', ' +
                                                              '@level1type = N''Table'', @level1name = ''' + SchemaSmith.fn_StripBracketWrapping(t.[Name]) + ''', ' +
                                                              '@level2type = N''Index'', @level2name = ''' + SchemaSmith.fn_StripBracketWrapping(i.IndexName) + ''';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #XmlIndexes i WITH (NOLOCK)
    JOIN #Tables t WITH (NOLOCK) ON t.[Schema] = i.[Schema] AND t.[Name] = i.[TableName]
    WHERE INDEXPROPERTY(OBJECT_ID(t.[Schema] + '.' + t.[Name]), SchemaSmith.fn_StripBracketWrapping(i.IndexName), 'IndexID') IS NOT NULL
      AND NOT EXISTS (SELECT * FROM #IndexProperties ip WITH (NOLOCK) WHERE i.[Schema] = ip.[Schema] AND i.TableName = ip.TableName AND SchemaSmith.fn_StripBracketWrapping(i.IndexName) = ip.IndexName AND ip.PropertyName = 'ProductName')
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Add Missing Statistics（补充缺失统计信息）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Creating statistics ' + s.[Schema] + '.' + s.[TableName] + '.' + s.[StatisticName] + '（创建统计信息）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'CREATE STATISTICS ' + s.[StatisticName] + ' ON ' + s.[Schema] + '.' + s.[TableName] + ' (' + s.[Columns] + ')' +
                                  CASE WHEN RTRIM(ISNULL(s.[FilterExpression], '')) <> '' THEN ' WHERE ' + s.[FilterExpression] ELSE '' END +
                                  ' WITH SAMPLE ' + CAST(ISNULL(s.[SampleSize], 100) AS NVARCHAR(20)) + ' PERCENT;' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #Statistics s WITH (NOLOCK)
    WHERE NOT EXISTS (SELECT * 
                        FROM sys.stats ss WITH (NOLOCK)
                        WHERE ss.[object_id] = OBJECT_ID(s.[Schema] + '.' + s.[TableName]) 
                          AND ss.[name] = SchemaSmith.fn_StripBracketWrapping(s.[StatisticName]))
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Add Missing Defaults（补充缺失默认值）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Altering Column ' + c.[Schema] + '.' + c.[TableName] + '.' + c.[ColumnName] + '（修改列）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + c.[Schema] + '.' + c.[TableName] + ' ADD DEFAULT ' + c.[Default] + ' FOR ' + c.[ColumnName] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #Columns c WITH (NOLOCK)
    WHERE RTRIM(ISNULL(c.[Default], '')) <> ''
      AND NOT EXISTS (SELECT * 
                        FROM sys.default_constraints dc WITH (NOLOCK)
                        WHERE dc.[parent_object_id] = OBJECT_ID(c.[Schema] + '.' + c.[TableName]) 
                          AND COL_NAME(dc.parent_object_id, dc.parent_column_id) = SchemaSmith.fn_StripBracketWrapping(c.ColumnName))
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Add Missing Check Constraints（补充缺失检查约束）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Adding check constraint ' + cc.[Schema] + '.' + cc.[TableName] + '.' + cc.[ConstraintName] + '（新增检查约束）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + cc.[Schema] + '.' + cc.[TableName] + ' ADD CONSTRAINT ' + cc.[ConstraintName] + ' CHECK (' + cc.[Expression] + ');' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #CheckConstraints cc WITH (NOLOCK)
    WHERE NOT EXISTS (SELECT * 
                        FROM sys.check_constraints sc WITH (NOLOCK)
                        WHERE sc.[parent_object_id] = OBJECT_ID(cc.[Schema] + '.' + cc.[TableName]) 
                          AND sc.[name] = SchemaSmith.fn_StripBracketWrapping(cc.[ConstraintName]))
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Adding check constrain to column ' + c.[Schema] + '.' + c.[TableName] + '.' + c.[ColumnName] + '（新增列检查约束）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + c.[Schema] + '.' + c.[TableName] + ' ADD CHECK (' + c.[CheckExpression] + ');' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #Columns c WITH (NOLOCK)
    WHERE RTRIM(ISNULL(c.[CheckExpression], '')) <> ''
      AND NOT EXISTS (SELECT * 
                        FROM sys.check_constraints sc WITH (NOLOCK)
                        WHERE sc.[parent_object_id] = OBJECT_ID(c.[Schema] + '.' + c.[TableName]) 
                          AND COL_NAME(sc.parent_object_id, sc.parent_column_id) = SchemaSmith.fn_StripBracketWrapping(c.[ColumnName]))
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Add Missing Foreign Keys（补充缺失外键）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Adding foreign key ' + f.[Schema] + '.' + f.[TableName] + '.' + f.[KeyName] + '（新增外键）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'ALTER TABLE ' + f.[Schema] + '.' + f.[TableName] + ' ADD CONSTRAINT ' + f.[KeyName] + ' FOREIGN KEY ' + 
                                  '(' + f.[Columns] + ') REFERENCES ' + [RelatedTableSchema] + '.' + f.[RelatedTable] + ' (' + [RelatedColumns] + ')' +
                                  ' ON DELETE ' + [DeleteAction] +
                                  ' ON UPDATE ' + [UpdateAction] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #ForeignKeys f WITH (NOLOCK)
    WHERE NOT EXISTS (SELECT *
                        FROM sys.foreign_keys sf WITH (NOLOCK)
                        WHERE sf.[parent_object_id] = OBJECT_ID(f.[Schema] + '.' + f.[TableName]) 
                          AND sf.[name] = SchemaSmith.fn_StripBracketWrapping(f.[KeyName]))
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  RAISERROR('Drop Modified or Removed FullText Indexes（删除已修改或移除的全文索引）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Dropping fulltext index on ' + ei.[Schema] + '.' + ei.[TableName] + '（删除全文索引）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'DROP FULLTEXT INDEX ON ' + ei.[Schema] + '.' + ei.[TableName] + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #ExistingFullTextIndexes ei WITH (NOLOCK)
    LEFT JOIN #FullTextIndexes fi WITH (NOLOCK) ON fi.[Schema] = ei.[Schema]
                                               AND fi.[TableName] = ei.[TableName]
    JOIN sys.fulltext_indexes ft WITH (NOLOCK) ON ft.[object_id] = OBJECT_ID(ei.[Schema] + '.' + ei.[TableName])
    WHERE RTRIM(ISNULL(fi.[Columns], '')) <> RTRIM(ISNULL(ei.[Columns], ''))
       OR SchemaSmith.fn_StripBracketWrapping(fi.[FullTextCatalog]) <> SchemaSmith.fn_StripBracketWrapping(ei.[FullTextCatalog])
       OR SchemaSmith.fn_StripBracketWrapping(fi.[KeyIndex]) <> SchemaSmith.fn_StripBracketWrapping(ei.[KeyIndex])
       OR fi.[ChangeTracking] <> ei.[ChangeTracking]
       OR RTRIM(ISNULL(fi.[StopList], '')) <> RTRIM(ISNULL(ei.[StopList], ''))
       OR fi.[TableName] IS NULL
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)

  RAISERROR('Add Missing FullText Indexes（补充缺失全文索引）', 10, 1) WITH NOWAIT
  SELECT @v_SQL = STRING_AGG(CAST('RAISERROR(''  Adding fulltext index on ' + fi.[Schema] + '.' + fi.[TableName] + '（新增全文索引）'', 10, 1) WITH NOWAIT;' + CHAR(13) + CHAR(10) +
                                  'CREATE FULLTEXT INDEX ON ' + fi.[Schema] + '.' + fi.[TableName] + ' (' + [Columns] + ') KEY INDEX ' + [KeyIndex] + ' ON ' + [FullTextCatalog] + 
                                  ' WITH CHANGE_TRACKING = ' + [ChangeTracking] +
                                  CASE WHEN RTRIM(ISNULL(fi.[StopList], '')) <> '' THEN ', STOPLIST = ' + [StopList] ELSE '' END + ';' AS NVARCHAR(MAX)), CHAR(13) + CHAR(10))
    FROM #FullTextIndexes fi WITH (NOLOCK)
    WHERE NOT EXISTS (SELECT * FROM sys.fulltext_indexes ft WITH (NOLOCK) WHERE ft.[object_id] = OBJECT_ID(fi.[Schema] + '.' + fi.[TableName]))
  IF @WhatIf = 1 PRINT @v_SQL ELSE EXEC(@v_SQL)
  
  SET NOCOUNT OFF
END TRY
BEGIN CATCH
  THROW
END CATCH
