{-# OPTIONS_GHC -Wwarn #-}
{-# LANGUAGE BangPatterns #-}
  -----------------------------------------------------------------------------
-- |
-- Module      :  Haddock.Interface.LexParseRn
-- Copyright   :  (c) Isaac Dupree 2009,
--                    Mateusz Kowalczyk 2013
-- License     :  BSD-like
--
-- Maintainer  :  haddock@projects.haskell.org
-- Stability   :  experimental
-- Portability :  portable
-----------------------------------------------------------------------------
module Haddock.Interface.LexParseRn
  ( processDocString
  , processDocStringParas
  , processDocStrings
  , processModuleHeader
  , docIdEnvRenamer
  ) where

import Data.List
import qualified Data.Map as Map
import Documentation.Haddock.Doc (metaDocConcat)
import qualified Documentation.Haddock.Parser as LibParser
import DynFlags (getDynFlags, languageExtensions, Language)
import qualified GHC.LanguageExtensions as LangExt
import GHC
import Haddock.Interface.ParseModuleHeader
import Haddock.Parser
import Haddock.Types
import Name
import Outputable ( showPpr, showSDoc )
import RdrName
import EnumSet
import RnEnv (dataTcOccs)

processDocStrings :: Maybe Package -> Renamer -> [HsDoc Name]
                  -> ErrMsgGhc (Maybe (MDoc Name))
processDocStrings pkg renamer strs = do
  mdoc <- metaDocConcat <$> traverse (processDocStringParas pkg renamer) strs
  case mdoc of
    -- We check that we don't have any version info to render instead
    -- of just checking if there is no comment: there may not be a
    -- comment but we still want to pass through any meta data.
    MetaDoc { _meta = Meta Nothing Nothing, _doc = DocEmpty } -> pure Nothing
    x -> pure (Just x)

processDocStringParas :: Maybe Package -> Renamer -> HsDoc Name -> ErrMsgGhc (MDoc Name)
processDocStringParas pkg renamer hsDoc =
  overDocF (rename renamer) $ LibParser.parseParas pkg (unpackHDS (hsDocString hsDoc))

processDocString :: Renamer -> HsDocString -> ErrMsgGhc (Doc Name)
processDocString renamer hds =
  rename renamer $ LibParser.parseString (unpackHDS hds)

processModuleHeader :: Maybe Package -> Renamer -> SafeHaskellMode
                    -> Maybe Language -> EnumSet LangExt.Extension
                    -> Maybe HsDocString
                    -> ErrMsgGhc (HaddockModInfo Name, Maybe (MDoc Name))
processModuleHeader pkgName renamer safety mayLang extSet mayStr = do
  (hmi, doc) <-
    case mayStr of
      Nothing -> return failure
      Just hds -> do
        let str = unpackHDS hds
            (hmi, doc) = parseModuleHeader pkgName str
        !descr <- case hmi_description hmi of
                    Just hmi_descr -> Just <$> rename renamer hmi_descr
                    Nothing        -> pure Nothing
        let hmi' = hmi { hmi_description = descr }
        doc'  <- overDocF (rename renamer) doc
        return (hmi', Just doc')

  dflags <- getDynFlags
  return (hmi { hmi_safety = Just $ showPpr dflags safety
              , hmi_language = mayLang
              , hmi_extensions = EnumSet.toList extSet
              } , doc)
  where
    failure = (emptyHaddockModInfo, Nothing)

-- | Takes a 'GlobalRdrEnv' which (hopefully) contains all the
-- definitions and a parsed comment and we attempt to make sense of
-- where the identifiers in the comment point to. We're in effect
-- trying to convert 'RdrName's to 'Name's, with some guesswork and
-- fallbacks in case we can't locate the identifiers.
--
-- See the comments in the source for implementation commentary.
rename :: Renamer -> Doc Identifier -> ErrMsgGhc (Doc Name)
rename renamer = rn
  where
    rn d = case d of
      DocAppend a b -> DocAppend <$> rn a <*> rn b
      DocParagraph doc -> DocParagraph <$> rn doc
      DocIdentifier id_@(_, x, _) -> do
        case renamer x of
          Nothing -> invalid id_

          -- There was nothing in the environment so we need to
          -- pick some default from what's available to us. We
          -- diverge here from the old way where we would default
          -- to type constructors as we're much more likely to
          -- actually want anchors to regular definitions than
          -- type constructor names (such as in #253). So now we
          -- only get type constructor links if they are actually
          -- in scope.
          Just [] -> outOfScope x

          -- There is only one name in the environment that matches so
          -- use it.
          Just [a] -> pure (DocIdentifier a)

          -- But when there are multiple names available, default to
          -- type constructors: somewhat awfully GHC returns the
          -- values in the list positionally.
          Just names@(a:b:_) -> ambiguous x (if isTyConName a then a else b) names

      DocWarning doc -> DocWarning <$> rn doc
      DocEmphasis doc -> DocEmphasis <$> rn doc
      DocBold doc -> DocBold <$> rn doc
      DocMonospaced doc -> DocMonospaced <$> rn doc
      DocUnorderedList docs -> DocUnorderedList <$> traverse rn docs
      DocOrderedList docs -> DocOrderedList <$> traverse rn docs
      DocDefList list -> DocDefList <$> traverse (\(a, b) -> (,) <$> rn a <*> rn b) list
      DocCodeBlock doc -> DocCodeBlock <$> rn doc
      DocIdentifierUnchecked x -> pure (DocIdentifierUnchecked x)
      DocModule str -> pure (DocModule str)
      DocHyperlink l -> pure (DocHyperlink l)
      DocPic str -> pure (DocPic str)
      DocMathInline str -> pure (DocMathInline str)
      DocMathDisplay str -> pure (DocMathDisplay str)
      DocAName str -> pure (DocAName str)
      DocProperty p -> pure (DocProperty p)
      DocExamples e -> pure (DocExamples e)
      DocEmpty -> pure (DocEmpty)
      DocString str -> pure (DocString str)
      DocHeader (Header l t) -> DocHeader . Header l <$> rn t
      DocTable t -> DocTable <$> traverse rn t

-- | TODO: We could emit a warning here.
invalid :: Identifier -> ErrMsgGhc (Doc a)
invalid (o, x, e) = pure (DocString $ o : x ++ [e])

-- | Wrap an identifier that's out of scope (i.e. wasn't found in
-- 'GlobalReaderEnv' during 'rename') in an appropriate doc. Currently
-- we simply monospace the identifier in most cases except when the
-- identifier is qualified: if the identifier is qualified then we can
-- still try to guess and generate anchors accross modules but the
-- users shouldn't rely on this doing the right thing. See tickets
-- #253 and #375 on the confusion this causes depending on which
-- default we pick in 'rename'.
outOfScope :: String -> ErrMsgGhc (Doc a)
outOfScope x = do
  dflags <- getDynFlags
  let warnAndMonospace a = do
        liftErrMsg $ tell ["Warning: '" ++ showPpr dflags a ++ "' is out of scope."]
        pure (monospaced a)
      monospaced a = DocMonospaced (DocString (showPpr dflags a))

  -- Using our local dflags isn't quite correct – ideally we'd use those GHC used when
  -- compiling the module
  case parseIdent dflags x of
    Nothing -> invalid ('\'', x, '\'') -- Shouldn't happen
    Just (rdr_name) -> case rdr_name of
      Unqual occ -> warnAndMonospace occ
      Qual mdl occ -> pure (DocIdentifierUnchecked (mdl, occ))
      Orig _ occ -> warnAndMonospace occ
      Exact name -> warnAndMonospace name  -- Shouldn't happen since x is out of scope

-- | Warn about an ambiguous identifier.
ambiguous :: String -> Name -> [Name] -> ErrMsgGhc (Doc Name)
ambiguous x dflt names = do
  dflags <- getDynFlags
  let msg = "Warning: " ++ x_str ++ " is ambiguous. It is defined\n" ++
            concatMap (\n -> "    * " ++ defnLoc n ++ "\n") names ++
            "    You may be able to disambiguate the identifier by qualifying it or\n" ++
            "    by hiding some imports.\n" ++
            "    Defaulting to " ++ x_str ++ " defined " ++ defnLoc dflt
      x_str = '\'' : x ++ "'"
      defnLoc = showSDoc dflags . pprNameDefnLoc
  liftErrMsg $ tell [msg]
  pure (DocIdentifier dflt)

docIdEnvRenamer :: DocIdEnv -> Renamer
docIdEnvRenamer doc_id_env s = Map.lookup s (Map.mapKeysMonotonic unpackHDS doc_id_env)
