{-# LANGUAGE UndecidableInstances #-}

module Hasura.RQL.IR.Returning
  ( MutFld,
    MutFldG (..),
    MutFlds,
    MutFldsG,
    MutationOutput,
    MutationOutputG (..),
    buildEmptyMutResp,
    hasNestedFld,
  )
where

import Data.Aeson qualified as J
import Data.HashMap.Strict.InsOrd qualified as OMap
import Data.Kind (Type)
import Hasura.EncJSON
import Hasura.Prelude
import Hasura.RQL.IR.Select
import Hasura.RQL.Types.Backend
import Hasura.SQL.Backend

data MutFldG (b :: BackendType) (r :: Type) v
  = MCount
  | MExp !Text
  | MRet !(AnnFieldsG b r v)
  deriving (Functor, Foldable, Traversable)

deriving instance (Show r, Backend b, Show (BooleanOperators b a), Show a) => Show (MutFldG b r a)

type MutFld b = MutFldG b Void (SQLExpression b)

type MutFldsG b r v = Fields (MutFldG b r v)

data MutationOutputG (b :: BackendType) (r :: Type) v
  = MOutMultirowFields !(MutFldsG b r v)
  | MOutSinglerowObject !(AnnFieldsG b r v)
  deriving (Functor, Foldable, Traversable)

deriving instance (Show (MutFldsG b r a), Show r, Backend b, Show (BooleanOperators b a), Show a) => Show (MutationOutputG b r a)

type MutationOutput b = MutationOutputG b Void (SQLExpression b)

type MutFlds b = MutFldsG b Void (SQLExpression b)

buildEmptyMutResp :: MutationOutput backend -> EncJSON
buildEmptyMutResp = \case
  MOutMultirowFields mutFlds -> encJFromJValue $ OMap.fromList $ map (second convMutFld) mutFlds
  MOutSinglerowObject _ -> encJFromJValue $ J.Object mempty
  where
    convMutFld = \case
      MCount -> J.toJSON (0 :: Int)
      MExp e -> J.toJSON e
      MRet _ -> J.toJSON ([] :: [J.Value])

hasNestedFld :: MutationOutputG backend r a -> Bool
hasNestedFld = \case
  MOutMultirowFields flds -> any isNestedMutFld flds
  MOutSinglerowObject annFlds -> any isNestedAnnField annFlds
  where
    isNestedMutFld (_, mutFld) = case mutFld of
      MRet annFlds -> any isNestedAnnField annFlds
      _ -> False
    isNestedAnnField (_, annFld) = case annFld of
      AFObjectRelation _ -> True
      AFArrayRelation _ -> True
      _ -> False
