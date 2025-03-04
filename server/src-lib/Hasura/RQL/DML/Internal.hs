module Hasura.RQL.DML.Internal
  ( SessionVariableBuilder,
    askDelPermInfo,
    askInsPermInfo,
    askPermInfo',
    askSelPermInfo,
    askUpdPermInfo,
    binRHSBuilder,
    checkPermOnCol,
    checkSelOnCol,
    convAnnBoolExpPartialSQL,
    convAnnColumnCaseBoolExpPartialSQL,
    convBoolExp,
    convPartialSQLExp,
    dmlTxErrorHandler,
    fetchRelDet,
    fetchRelTabInfo,
    fromCurrentSession,
    getPermInfoMaybe,
    getRolePermInfo,
    isTabUpdatable,
    onlyPositiveInt,
    runDMLP1T,
    sessVarFromCurrentSetting,
    validateHeaders,
    valueParserWithCollectableType,
    verifyAsrns,
    withTypeAnn,
  )
where

import Control.Lens
import Data.Aeson.Types
import Data.HashMap.Strict qualified as M
import Data.HashSet qualified as HS
import Data.Sequence qualified as DS
import Data.Text qualified as T
import Data.Text.Extended
import Database.PG.Query qualified as Q
import Hasura.Backends.Postgres.SQL.DML qualified as S
import Hasura.Backends.Postgres.SQL.Error
import Hasura.Backends.Postgres.SQL.Types hiding (TableName)
import Hasura.Backends.Postgres.SQL.Value
import Hasura.Backends.Postgres.Translate.BoolExp
import Hasura.Backends.Postgres.Translate.Column
import Hasura.Backends.Postgres.Types.Column
import Hasura.Base.Error
import Hasura.Prelude
import Hasura.RQL.Types
import Hasura.SQL.Types
import Hasura.Session

newtype DMLP1T m a = DMLP1T {unDMLP1T :: StateT (DS.Seq Q.PrepArg) m a}
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadTrans,
      MonadState (DS.Seq Q.PrepArg),
      MonadError e,
      SourceM,
      TableCoreInfoRM b,
      TableInfoRM b,
      CacheRM,
      UserInfoM,
      HasServerConfigCtx
    )

runDMLP1T :: DMLP1T m a -> m (a, DS.Seq Q.PrepArg)
runDMLP1T = flip runStateT DS.empty . unDMLP1T

mkAdminRolePermInfo :: Backend b => TableCoreInfo b -> RolePermInfo b
mkAdminRolePermInfo ti =
  RolePermInfo (Just i) (Just s) (Just u) (Just d)
  where
    fields = _tciFieldInfoMap ti
    pgCols = map ciColumn $ getCols fields
    pgColsWithFilter = M.fromList $ map (,Nothing) pgCols
    scalarComputedFields =
      HS.fromList $ map _cfiName $ onlyScalarComputedFields $ getComputedFieldInfos fields
    scalarComputedFields' = HS.toMap scalarComputedFields $> Nothing

    tn = _tciName ti
    i = InsPermInfo (HS.fromList pgCols) annBoolExpTrue M.empty False mempty
    s = SelPermInfo pgColsWithFilter scalarComputedFields' annBoolExpTrue Nothing True mempty
    u = UpdPermInfo (HS.fromList pgCols) tn annBoolExpTrue Nothing M.empty mempty
    d = DelPermInfo tn annBoolExpTrue mempty

askPermInfo' ::
  (UserInfoM m, Backend b) =>
  PermAccessor b c ->
  TableInfo b ->
  m (Maybe c)
askPermInfo' pa tableInfo = do
  role <- askCurRole
  return $ getPermInfoMaybe role pa tableInfo

getPermInfoMaybe ::
  (Backend b) => RoleName -> PermAccessor b c -> TableInfo b -> Maybe c
getPermInfoMaybe role pa tableInfo =
  getRolePermInfo role tableInfo >>= (^. permAccToLens pa)

getRolePermInfo ::
  Backend b => RoleName -> TableInfo b -> Maybe (RolePermInfo b)
getRolePermInfo role tableInfo
  | role == adminRoleName =
    Just $ mkAdminRolePermInfo (_tiCoreInfo tableInfo)
  | otherwise =
    M.lookup role (_tiRolePermInfoMap tableInfo)

askPermInfo ::
  (UserInfoM m, QErrM m, Backend b) =>
  PermAccessor b c ->
  TableInfo b ->
  m c
askPermInfo pa tableInfo = do
  roleName <- askCurRole
  mPermInfo <- askPermInfo' pa tableInfo
  onNothing mPermInfo $
    throw400 PermissionDenied $
      mconcat
        [ pt <> " on " <>> tableInfoName tableInfo,
          " for role " <>> roleName,
          " is not allowed. "
        ]
  where
    pt = permTypeToCode $ permAccToType pa

isTabUpdatable :: RoleName -> TableInfo ('Postgres pgKind) -> Bool
isTabUpdatable role ti
  | role == adminRoleName = True
  | otherwise = isJust $ M.lookup role rpim >>= _permUpd
  where
    rpim = _tiRolePermInfoMap ti

askInsPermInfo ::
  (UserInfoM m, QErrM m, Backend b) =>
  TableInfo b ->
  m (InsPermInfo b)
askInsPermInfo = askPermInfo PAInsert

askSelPermInfo ::
  (UserInfoM m, QErrM m, Backend b) =>
  TableInfo b ->
  m (SelPermInfo b)
askSelPermInfo = askPermInfo PASelect

askUpdPermInfo ::
  (UserInfoM m, QErrM m, Backend b) =>
  TableInfo b ->
  m (UpdPermInfo b)
askUpdPermInfo = askPermInfo PAUpdate

askDelPermInfo ::
  (UserInfoM m, QErrM m, Backend b) =>
  TableInfo b ->
  m (DelPermInfo b)
askDelPermInfo = askPermInfo PADelete

verifyAsrns :: (MonadError QErr m) => [a -> m ()] -> [a] -> m ()
verifyAsrns preds xs = indexedForM_ xs $ \a -> mapM_ ($ a) preds

checkSelOnCol ::
  forall b m.
  (UserInfoM m, QErrM m, Backend b) =>
  SelPermInfo b ->
  Column b ->
  m ()
checkSelOnCol selPermInfo =
  checkPermOnCol @b PTSelect (HS.fromList $ M.keys $ spiCols @b selPermInfo)

checkPermOnCol ::
  forall b m.
  (UserInfoM m, QErrM m, Backend b) =>
  PermType ->
  HS.HashSet (Column b) ->
  Column b ->
  m ()
checkPermOnCol pt allowedCols col = do
  role <- askCurRole
  unless (HS.member col allowedCols) $
    throw400 PermissionDenied $ permErrMsg role
  where
    permErrMsg role
      | role == adminRoleName = "no such column exists : " <>> col
      | otherwise =
        mconcat
          [ "role " <>> role,
            " does not have permission to ",
            permTypeToCode pt <> " column " <>> col
          ]

checkSelectPermOnScalarComputedField ::
  forall b m.
  (UserInfoM m, QErrM m) =>
  SelPermInfo b ->
  ComputedFieldName ->
  m ()
checkSelectPermOnScalarComputedField selPermInfo computedField = do
  role <- askCurRole
  unless (M.member computedField $ spiScalarComputedFields selPermInfo) $
    throw400 PermissionDenied $ permErrMsg role
  where
    permErrMsg role
      | role == adminRoleName = "no such computed field exists : " <>> computedField
      | otherwise =
        "role " <> role <<> " does not have permission to select computed field" <>> computedField

valueParserWithCollectableType ::
  forall pgKind m.
  (Backend ('Postgres pgKind), MonadError QErr m) =>
  (ColumnType ('Postgres pgKind) -> Value -> m S.SQLExp) ->
  CollectableType (ColumnType ('Postgres pgKind)) ->
  Value ->
  m S.SQLExp
valueParserWithCollectableType valBldr pgType val = case pgType of
  CollectableTypeScalar ty -> valBldr ty val
  CollectableTypeArray ofTy -> do
    -- for arrays, we don't use the prepared builder
    vals <- runAesonParser parseJSON val
    scalarValues <- parseScalarValuesColumnType ofTy vals
    return $
      S.SETyAnn
        (S.SEArray $ map (toTxtValue . ColumnValue ofTy) scalarValues)
        (S.mkTypeAnn $ CollectableTypeArray (unsafePGColumnToBackend ofTy))

binRHSBuilder ::
  forall pgKind m.
  (Backend ('Postgres pgKind), QErrM m) =>
  ColumnType ('Postgres pgKind) ->
  Value ->
  DMLP1T m S.SQLExp
binRHSBuilder colType val = do
  preparedArgs <- get
  scalarValue <- parseScalarValueColumnType colType val
  put (preparedArgs DS.|> binEncoder scalarValue)
  return $ toPrepParam (DS.length preparedArgs + 1) (unsafePGColumnToBackend colType)

fetchRelTabInfo ::
  (QErrM m, TableInfoRM b m, Backend b) =>
  TableName b ->
  m (TableInfo b)
fetchRelTabInfo refTabName =
  -- Internal error
  modifyErrAndSet500 ("foreign " <>) $
    askTabInfoSource refTabName

data SessionVariableBuilder b m = SessionVariableBuilder
  { _svbCurrentSession :: !(SQLExpression b),
    _svbVariableParser :: !(SessionVarType b -> SessionVariable -> m (SQLExpression b))
  }

fetchRelDet ::
  (UserInfoM m, QErrM m, TableInfoRM b m, Backend b) =>
  RelName ->
  TableName b ->
  m (FieldInfoMap (FieldInfo b), SelPermInfo b)
fetchRelDet relName refTabName = do
  roleName <- askCurRole
  -- Internal error
  refTabInfo <- fetchRelTabInfo refTabName
  -- Get the correct constraint that applies to the given relationship
  refSelPerm <-
    modifyErr (relPermErr refTabName roleName) $
      askSelPermInfo refTabInfo

  return (_tciFieldInfoMap $ _tiCoreInfo refTabInfo, refSelPerm)
  where
    relPermErr rTable roleName _ =
      mconcat
        [ "role " <>> roleName,
          " does not have permission to read relationship " <>> relName,
          "; no permission on",
          " table " <>> rTable
        ]

checkOnColExp ::
  (UserInfoM m, QErrM m, TableInfoRM b m, Backend b) =>
  SelPermInfo b ->
  SessionVariableBuilder b m ->
  AnnBoolExpFldSQL b ->
  m (AnnBoolExpFldSQL b)
checkOnColExp spi sessVarBldr annFld = case annFld of
  AVColumn colInfo _ -> do
    let cn = ciColumn colInfo
    checkSelOnCol spi cn
    return annFld
  AVRelationship relInfo nesAnn -> do
    relSPI <- snd <$> fetchRelDet (riName relInfo) (riRTable relInfo)
    modAnn <- checkSelPerm relSPI sessVarBldr nesAnn
    resolvedFltr <- convAnnBoolExpPartialSQL sessVarBldr $ spiFilter relSPI
    return $ AVRelationship relInfo $ andAnnBoolExps modAnn resolvedFltr
  AVComputedField cfBoolExp -> do
    roleName <- askCurRole
    let fieldName = _acfbName cfBoolExp
    case _acfbBoolExp cfBoolExp of
      CFBEScalar _ -> do
        checkSelectPermOnScalarComputedField spi fieldName
        pure annFld
      CFBETable table nesBoolExp -> do
        tableInfo <- modifyErrAndSet500 ("function " <>) $ askTabInfoSource table
        let errMsg _ =
              "role " <> roleName <<> " does not have permission to read "
                <> " computed field "
                <> fieldName <<> "; no permission on table " <>> table
        tableSPI <- modifyErr errMsg $ askSelPermInfo tableInfo
        modBoolExp <- checkSelPerm tableSPI sessVarBldr nesBoolExp
        resolvedFltr <- convAnnBoolExpPartialSQL sessVarBldr $ spiFilter tableSPI
        -- Including table permission filter; "input condition" AND "permission filter condition"
        let finalBoolExp = andAnnBoolExps modBoolExp resolvedFltr
        pure $ AVComputedField cfBoolExp {_acfbBoolExp = CFBETable table finalBoolExp}

convAnnBoolExpPartialSQL ::
  (Applicative f, Backend backend) =>
  SessionVariableBuilder backend f ->
  AnnBoolExpPartialSQL backend ->
  f (AnnBoolExpSQL backend)
convAnnBoolExpPartialSQL f =
  (traverse . traverse) (convPartialSQLExp f)

convAnnColumnCaseBoolExpPartialSQL ::
  (Applicative f, Backend backend) =>
  SessionVariableBuilder backend f ->
  AnnColumnCaseBoolExpPartialSQL backend ->
  f (AnnColumnCaseBoolExp backend (SQLExpression backend))
convAnnColumnCaseBoolExpPartialSQL f =
  (traverse . traverse) (convPartialSQLExp f)

convPartialSQLExp ::
  (Applicative f) =>
  SessionVariableBuilder backend f ->
  PartialSQLExp backend ->
  f (SQLExpression backend)
convPartialSQLExp sessVarBldr = \case
  PSESQLExp sqlExp -> pure sqlExp
  PSESession -> pure $ _svbCurrentSession sessVarBldr
  PSESessVar colTy sessionVariable -> (_svbVariableParser sessVarBldr) colTy sessionVariable

sessVarFromCurrentSetting ::
  (Applicative f) => SessionVariableBuilder ('Postgres pgKind) f
sessVarFromCurrentSetting =
  SessionVariableBuilder currentSession $ \ty var -> pure $ sessVarFromCurrentSetting' ty var

sessVarFromCurrentSetting' :: CollectableType PGScalarType -> SessionVariable -> S.SQLExp
sessVarFromCurrentSetting' ty sessVar =
  withTypeAnn ty $ fromCurrentSession currentSession sessVar

withTypeAnn :: CollectableType PGScalarType -> S.SQLExp -> S.SQLExp
withTypeAnn ty sessVarVal = flip S.SETyAnn (S.mkTypeAnn ty) $
  case ty of
    CollectableTypeScalar baseTy -> withConstructorFn baseTy sessVarVal
    CollectableTypeArray _ -> sessVarVal

fromCurrentSession ::
  S.SQLExp ->
  SessionVariable ->
  S.SQLExp
fromCurrentSession currentSessionExp sessVar =
  S.SEOpApp
    (S.SQLOp "->>")
    [currentSessionExp, S.SELit $ sessionVariableToText sessVar]

currentSession :: S.SQLExp
currentSession = S.SEUnsafe "current_setting('hasura.user')::json"

checkSelPerm ::
  (UserInfoM m, QErrM m, TableInfoRM b m, Backend b) =>
  SelPermInfo b ->
  SessionVariableBuilder b m ->
  AnnBoolExpSQL b ->
  m (AnnBoolExpSQL b)
checkSelPerm spi sessVarBldr =
  traverse (checkOnColExp spi sessVarBldr)

convBoolExp ::
  (UserInfoM m, QErrM m, TableInfoRM b m, BackendMetadata b) =>
  FieldInfoMap (FieldInfo b) ->
  SelPermInfo b ->
  BoolExp b ->
  SessionVariableBuilder b m ->
  TableName b ->
  ValueParser b m (SQLExpression b) ->
  m (AnnBoolExpSQL b)
convBoolExp cim spi be sessVarBldr rootTable rhsParser = do
  let boolExpRHSParser = BoolExpRHSParser rhsParser $ _svbCurrentSession sessVarBldr
  abe <- annBoolExp boolExpRHSParser rootTable cim $ unBoolExp be
  checkSelPerm spi sessVarBldr abe

dmlTxErrorHandler :: Q.PGTxErr -> QErr
dmlTxErrorHandler = mkTxErrorHandler $ \case
  PGIntegrityConstraintViolation _ -> True
  PGDataException _ -> True
  PGSyntaxErrorOrAccessRuleViolation (Just (PGErrorSpecific code)) ->
    code
      `elem` [ PGUndefinedObject,
               PGInvalidColumnReference
             ]
  _ -> False

-- validate headers
validateHeaders :: (UserInfoM m, QErrM m) => HashSet Text -> m ()
validateHeaders depHeaders = do
  headers <- getSessionVariables . _uiSession <$> askUserInfo
  forM_ depHeaders $ \hdr ->
    unless (hdr `elem` map T.toLower headers) $
      throw400 NotFound $ hdr <<> " header is expected but not found"

-- validate limit and offset int values
onlyPositiveInt :: MonadError QErr m => Int -> m ()
onlyPositiveInt i =
  when (i < 0) $
    throw400
      NotSupported
      "unexpected negative value"
