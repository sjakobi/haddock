--
-- Haddock - A Haskell Documentation Tool
--
-- (c) Simon Marlow 2002
--

module HaddockTypes (
  -- * Module interfaces
  NameEnv, Interface(..), ExportItem(..), ModuleMap,

  -- * Misc types
  DocOption(..), InstHead,
 ) where

#if __GLASGOW_HASKELL__ < 503
import FiniteMap
#else
import Data.FiniteMap
#endif

import HsSyn

-- ---------------------------------------------------------------------------
-- Describing a module interface

type NameEnv   = FiniteMap HsName HsQName

data Interface 
  = Interface {
	iface_filename :: FilePath,
		-- ^ the filename that contains the source code for this module

	iface_package :: Maybe String,

	iface_env :: NameEnv,
		-- ^ environment mapping names to *original* names

	iface_import_env :: FiniteMap HsQName HsQName,

	iface_reexported :: NameEnv,
		-- ^ For names exported by this module, but not
		-- actually documented in this module's documentation
		-- (perhaps because they are reexported via 'module M'
		-- in the export list), this mapping gives the
		-- location of documentation for the name in another
		-- module.

	iface_sub :: FiniteMap HsName [HsName],
		-- ^ maps names to "subordinate" names 
		-- (eg. tycon to constrs & fields, class to methods)

	iface_exports :: [ExportItem],
		-- ^ the exports used to construct the documentation 

	iface_orig_exports :: [ExportItem],
		-- ^ the exports used to construct the documentation
		-- (with orig names, not import names)

	iface_decls :: FiniteMap HsName HsDecl,
		-- ^ decls from this module (only)
		-- restricted to only those bits exported.
		-- the map key is the "main name" of the decl.

	iface_insts :: [HsDecl],
		-- ^ instances from this module

	iface_info :: Maybe ModuleInfo,
		-- ^ information from the module header

	iface_doc :: Maybe Doc,
		-- ^ documentation from the module header

	iface_options :: [DocOption]
		-- ^ module-wide doc options
  }

data DocOption = OptHide | OptPrune | OptIgnoreExports 
  deriving (Eq)

data ExportItem 
  = ExportDecl
	HsQName		-- the original name
	HsDecl		-- a declaration (with doc annotations)
	[InstHead]	-- instances relevant to this declaration

  | ExportNoDecl	-- an exported entity for which we have no documentation
			-- (perhaps becuase it resides in another package)
	HsQName		-- the original name
	HsQName		-- where to link to
	[HsQName]	-- subordinate names

  | ExportGroup		-- a section heading
	Int		-- section level (1, 2, 3, ... )
	String		-- section "id" (for hyperlinks)
	Doc		-- section heading text

  | ExportDoc		-- some documentation
	Doc

  | ExportModule	-- a cross-reference to another module
	Module

type ModuleMap = FiniteMap Module Interface

type InstHead = (HsContext,HsAsst)
