-----------------------------------------------------------------------------
--
-- Module      :  Main
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Main where

import Control.Applicative
import Control.Monad
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Reader
import Control.Monad.Supply (evalSupplyT)
import Control.Monad.Writer

import Data.Maybe (fromMaybe)
import Data.Traversable (traverse)
import Data.Version (showVersion)

import Options.Applicative as Opts

import System.Directory (createDirectoryIfMissing)
import System.Exit (exitSuccess, exitFailure)
import System.FilePath (takeDirectory)
import System.IO (hPutStrLn, stderr)

import qualified Data.Map as M
import qualified Language.PureScript as P
import qualified Language.PureScript.CodeGen.JS as J
import qualified Language.PureScript.Constants as C
import qualified Language.PureScript.CoreFn as CF
import qualified Paths_purescript as Paths


import Foreign

data PSCOptions = PSCOptions
  { pscInput        :: [FilePath]
  , pscForeignInput :: [FilePath]
  , pscOpts         :: P.Options P.Compile
  , pscStdIn        :: Bool
  , pscOutput       :: Maybe FilePath
  , pscExterns      :: Maybe FilePath
  , pscUsePrefix    :: Bool
  }

data InputOptions = InputOptions
  { ioNoPrelude  :: Bool
  , ioUseStdIn   :: Bool
  , ioInputFiles :: [FilePath]
  }

readInput :: InputOptions -> IO [(Maybe FilePath, String)]
readInput InputOptions{..}
  | ioUseStdIn = return . (Nothing ,) <$> getContents
  | otherwise = forM ioInputFiles $ \inFile -> (Just inFile, ) <$> readFile inFile

type PSC = ReaderT (P.Options P.Compile) (WriterT P.MultipleErrors (Either P.MultipleErrors))

runPSC :: P.Options P.Compile -> PSC a -> Either P.MultipleErrors (a, P.MultipleErrors)
runPSC opts rwe = runWriterT (runReaderT rwe opts)

compile :: PSCOptions -> IO ()
compile (PSCOptions input inputForeign opts stdin output externs usePrefix) = do
  let prefix = ["Generated by psc version " ++ showVersion Paths.version | usePrefix]
  moduleFiles <- readInput (InputOptions (P.optionsNoPrelude opts) stdin input)
  foreignFiles <- forM inputForeign (\inFile -> (inFile,) <$> readFile inFile)
  case parseInputs moduleFiles foreignFiles of
    Left err -> do
      hPutStrLn stderr err
      exitFailure
    Right (ms, foreigns) ->
      case runPSC opts (compileJS (map snd ms) foreigns prefix) of
        Left errs -> do
          hPutStrLn stderr (P.prettyPrintMultipleErrors (P.optionsVerboseErrors opts) errs)
          exitFailure
        Right ((js, exts), warnings) -> do
          when (P.nonEmpty warnings) $
            hPutStrLn stderr (P.prettyPrintMultipleWarnings (P.optionsVerboseErrors opts) warnings)
          case output of
            Just path -> mkdirp path >> writeFile path js
            Nothing -> putStrLn js
          case externs of
            Just path -> mkdirp path >> writeFile path exts
            Nothing -> return ()
          exitSuccess

parseInputs :: [(Maybe FilePath, String)] -> [(FilePath, String)] -> Either String ([(Maybe FilePath, P.Module)], M.Map P.ModuleName String)
parseInputs modules foreigns =
  (,) <$> either (Left . show) Right (P.parseModulesFromFiles (fromMaybe "") modules)
      <*> parseForeignModulesFromFiles foreigns

compileJS :: forall m. (Functor m, Applicative m, MonadError P.MultipleErrors m, MonadWriter P.MultipleErrors m, MonadReader (P.Options P.Compile) m)
          => [P.Module] -> M.Map P.ModuleName String -> [String] -> m (String, String)
compileJS ms foreigns prefix = do
  (modulesToCodeGen, exts, env, nextVar) <- P.compile ms
  js <- concat <$> evalSupplyT nextVar (traverse codegenModule modulesToCodeGen)
  js' <- generateMain env js
  let pjs = unlines $ map ("// " ++) prefix ++ [P.prettyPrintJS js']
  return (pjs, exts)

  where

  --codegenModule :: CF.Module CF.Ann -> m [J.JS]
  codegenModule m =
    J.moduleToJs m $ (\js -> J.JSApp (J.JSFunction Nothing [] (J.JSBlock
          [ J.JSVariableIntroduction "exports" (Just $ J.JSObjectLiteral [])
          , J.JSRaw js
          , J.JSReturn (J.JSVar "exports")
          ])) []) <$> CF.moduleName m `M.lookup` foreigns

  generateMain :: P.Environment -> [J.JS] -> m [J.JS]
  generateMain env js = do
    mainName <- asks P.optionsMain
    additional <- asks P.optionsAdditional
    case P.moduleNameFromString <$> mainName of
      Just mmi -> do
        when ((mmi, P.Ident C.main) `M.notMember` P.names env) $
          throwError . P.errorMessage $ P.NameIsUndefined (P.Ident C.main)
        return $ js ++ [J.mainCall mmi (P.browserNamespace additional)]
      _ -> return js

mkdirp :: FilePath -> IO ()
mkdirp = createDirectoryIfMissing True . takeDirectory

codeGenModule :: Parser String
codeGenModule = strOption $
     long "codegen"
  <> help "A list of modules for which Javascript and externs should be generated. This argument can be used multiple times."

dceModule :: Parser String
dceModule = strOption $
     short 'm'
  <> long "module"
  <> help "Enables dead code elimination, all code which is not a transitive dependency of a specified module will be removed. This argument can be used multiple times."

browserNamespace :: Parser String
browserNamespace = strOption $
     long "browser-namespace"
  <> Opts.value "PS"
  <> showDefault
  <> help "Specify the namespace that PureScript modules will be exported to when running in the browser."

verboseErrors :: Parser Bool
verboseErrors = switch $
     short 'v'
  <> long "verbose-errors"
  <> help "Display verbose error messages"

noOpts :: Parser Bool
noOpts = switch $
     long "no-opts"
  <> help "Skip the optimization phase."

runMain :: Parser (Maybe String)
runMain = optional $ noArgs <|> withArgs
  where
  defaultVal = "Main"
  noArgs     = flag' defaultVal (long "main")
  withArgs   = strOption $
        long "main"
     <> help (concat [
            "Generate code to run the main method in the specified module. ",
            "(no argument: \"", defaultVal, "\")"
        ])

noMagicDo :: Parser Bool
noMagicDo = switch $
     long "no-magic-do"
  <> help "Disable the optimization that overloads the do keyword to generate efficient code specifically for the Eff monad."

noTco :: Parser Bool
noTco = switch $
     long "no-tco"
  <> help "Disable tail call optimizations"

noPrelude :: Parser Bool
noPrelude = switch $
     long "no-prelude"
  <> help "Omit the automatic Prelude import"

comments :: Parser Bool
comments = switch $
     short 'c'
  <> long "comments"
  <> help "Include comments in the generated code."

useStdIn :: Parser Bool
useStdIn = switch $
     short 's'
  <> long "stdin"
  <> help "Read from standard input"

inputFile :: Parser FilePath
inputFile = strArgument $
     metavar "FILE"
  <> help "The input .purs file(s)"

inputForeignFile :: Parser FilePath
inputForeignFile = strOption $
     short 'f'
  <> long "ffi"
  <> help "The input .js file(s) providing foreign import implementations"

outputFile :: Parser (Maybe FilePath)
outputFile = optional . strOption $
     short 'o'
  <> long "output"
  <> help "The output .js file"

externsFile :: Parser (Maybe FilePath)
externsFile = optional . strOption $
     short 'e'
  <> long "externs"
  <> help "The output .e.purs file"

noPrefix :: Parser Bool
noPrefix = switch $
     short 'p'
  <> long "no-prefix"
  <> help "Do not include comment header"

options :: Parser (P.Options P.Compile)
options = P.Options <$> noPrelude
                    <*> noTco
                    <*> noMagicDo
                    <*> runMain
                    <*> noOpts
                    <*> verboseErrors
                    <*> (not <$> comments)
                    <*> additionalOptions
  where
  additionalOptions =
    P.CompileOptions <$> browserNamespace
                     <*> many dceModule
                     <*> many codeGenModule

pscOptions :: Parser PSCOptions
pscOptions = PSCOptions <$> many inputFile
                        <*> many inputForeignFile
                        <*> options
                        <*> useStdIn
                        <*> outputFile
                        <*> externsFile
                        <*> (not <$> noPrefix)

main :: IO ()
main = execParser opts >>= compile
  where
  opts        = info (version <*> helper <*> pscOptions) infoModList
  infoModList = fullDesc <> headerInfo <> footerInfo
  headerInfo  = header   "psc - Compiles PureScript to Javascript"
  footerInfo  = footer $ "psc " ++ showVersion Paths.version

  version :: Parser (a -> a)
  version = abortOption (InfoMsg (showVersion Paths.version)) $ long "version" <> help "Show the version number" <> hidden
