module IRTS.CodegenMalfunction(codegenMalfunction) where

import Idris.Core.TT
import qualified Idris.Core.CaseTree as CaseTree
import IRTS.CodegenCommon
import IRTS.Lang
import IRTS.Simplified

import Data.List
import Data.Char
import Data.Ord
import qualified Data.Set as S
import qualified Data.Graph as Graph
import Data.Function (on)
import Control.Monad

import System.Process
import System.Directory

import qualified Data.Text as Text

data Sexp = S [Sexp] | A String | KInt Int | KStr String

instance Show Sexp where
  show s = render s "" where
    render (S s) k = "(" ++ foldr render (") " ++ k) s
    render (A s) k = s ++ " " ++ k
    render (KInt n) k = show n ++ " " ++ k
    render (KStr s) k = show s ++ " " ++ k


okChar c = (isAscii c && isAlpha c) || isDigit c || c `elem` ".&|$+-!@#^*~?<>=_"

cgSym s = A ('$' : chars s)
  where
    chars (c:cs) | okChar c = c:chars cs
                 | otherwise = "%" ++ show (ord c) ++ "%" ++ chars cs
    chars [] = []

codegenMalfunction :: CodeGenerator
codegenMalfunction ci = do
  writeFile tmp $ show $
    S (A "module" : shuffle (simpleDecls ci)
       [S [A "_", S [A "apply", cgName (sMN 0 "runMain"), KInt 0]],
        S [A "export"]])
  callCommand $ "malfunction compile -o '" ++ outputFile ci ++ "' '" ++ tmp ++ "'"
  removeFile tmp
  where
    tmp = "idris_malfunction_output.mlf"

shuffle decls rest = prelude ++ toBindings (Graph.stronglyConnComp (map toNode decls))
  where
    toBindings [] = rest
    toBindings (Graph.AcyclicSCC decl : comps) = cgDecl decl : toBindings comps
    toBindings (Graph.CyclicSCC decls : comps) = S (A "rec" : map cgDecl decls) : toBindings comps
    
    toNode decl@(name, SFun _ _ _ body) =
      (decl, name, S.toList (free body))

    freev (Glob n) = S.singleton n
    freev (Loc k) = S.empty

    -- stupid over-approximation, since global names not shadowed
    free (SV v) = freev v
    free (SApp _ n _) = S.singleton n
    free (SLet v e1 e2) = S.unions [freev v, free e1, free e2]
    free (SUpdate v e) = S.unions [freev v, free e]
    free (SCon (Just v) _ n vs) = S.unions (freev v : S.singleton n : map freev vs)
    free (SCon Nothing _ n vs) = S.unions (S.singleton n : map freev vs)    
    free (SCase _ v cases) = S.unions (freev v : map freeCase cases)
    free (SChkCase v cases) = S.unions (freev v : map freeCase cases)
    free (SProj v _) = freev v
    free (SConst _) = S.empty
    free (SForeign _ _ args) = S.unions (map (freev . snd) args)
    free (SOp _ args) = S.unions (map freev args)
    free (SNothing) = S.empty
    free (SError s) = S.empty

    freeCase (SConCase _ _ n ns e) = S.unions [S.singleton n, S.fromList ns, free e]
    freeCase (SConstCase _ e) = free e
    freeCase (SDefaultCase e) = free e

    prelude = [
      S [A"$%strrev",
         S [A"lambda", S [A"$s"],
              S [A"let", S [A"$n", S [A"-", S [A"length.byte", A"$s"], KInt 1]],
                 S [A"apply", S[A"global", A"$String", A"$mapi"],
                    S[A"lambda", S[A"$i", A"$c"],
                      S[A"load.byte", A"$s", S[A"-", A"$n", A"$i"]]],
                    A"$s"]]]],
      S [A"rec",
         S [A"$%mklist",
            S [A"lambda", S [A"$f", A"$l"],
              S [A"switch", A"$l",
                 S [S [A"tag", KInt 0], KInt 0],
                 S [S [A"tag", KInt 1], S [A"block", S [A"tag", KInt 0],
                                                     S [A"apply", A"$f", S [A"field", KInt 1, A"$l"]],
                                                     S [A"apply", A"$%mklist", A"$f", S [A"field", KInt 2, A"$l"]]]]]]]],
      S [A"rec",
         S [A"$%unmklist",
            S [A"lambda", S [A"$f", A"$l"],
               S [A"switch", A"$l",
                  S [KInt 0, S [A"block", S [A"tag", KInt 0], KInt 0]],
                  S [S [A"tag", KInt 0], S [A"block", S [A"tag", KInt 1],
                                                         KInt 1, -- the hours I spent trying to figure out that I'd missed this line
                                                         S [A"apply", A"$f", S [A"field", KInt 0, A"$l"]],
                                                         S [A"apply", A"$%unmklist", A"$f", S [A"field", KInt 1, A"$l"]]]]]]]]]

cgName :: Name -> Sexp
cgName = cgSym . showCG

cgVar (Loc n) = cgSym (show n)
cgVar (Glob n) = cgName n

cgDecl :: (Name, SDecl) -> Sexp
cgDecl (name, SFun _ args i body) = S [cgName name, S [A "lambda", mkargs args, cgExp body]]
  where
    mkargs [] = S [A "$%unused"]
    mkargs args = S $ map (cgVar . Loc . fst) $ zip [0..] args

cgExp :: SExp -> Sexp
cgExp (SV v) = cgVar v
cgExp (SApp _ fn []) = S [A "apply", cgName fn, KInt 0]
cgExp (SApp _ fn args) = S (A "apply" : cgName fn : map cgVar args)
cgExp (SLet v e body) = S [A "let", S [cgVar v, cgExp e], cgExp body]
cgExp (SUpdate v e) = cgExp e
cgExp (SProj e idx) = S [A "field", KInt (idx + 1), cgVar e]
cgExp (SCon _ tag name args) = S (A "block": S [A "tag", KInt (tag `mod` 200)] : KInt tag : map cgVar args)
cgExp (SCase _ e cases) = cgSwitch e cases
cgExp (SChkCase e cases) = cgSwitch e cases
cgExp (SConst k) = cgConst k
cgExp (SForeign ret fn args) = cgForeign ret fn args
cgExp (SOp prim args) = cgOp prim args
cgExp SNothing = KInt 0
cgExp (SError s) = S [A "apply", S [A "global", A "$Pervasives", A "$failwith"], KStr $ "error: " ++ show s]

cgForeign :: FDesc -> FDesc -> [(FDesc, LVar)] -> Sexp
cgForeign ret fn [] = S [A "apply", fromOCaml (ocamlType ret), S ((A "global") : cgFDesc fn)]
cgForeign ret fn args = S [A "apply", fromOCaml (ocamlType ret), S ([A "apply", S ((A "global") : cgFDesc fn)] ++ mkargs args)]
  where

    mkargs :: [(FDesc, LVar)] -> [Sexp]
    mkargs [] = [KInt 0]
    mkargs xs = map mkargs' xs
      where
        mkargs' (fdesc, lv) = S [A "apply", toOCaml (ocamlType fdesc), cgVar lv]

cgFDesc :: FDesc -> [Sexp]
cgFDesc (FCon name) = [cgName name]
cgFDesc (FStr s) = map (cgSym . str) $ Text.splitOn (txt ".") (txt s)
cgFDesc FUnknown = undefined
cgFDesc (FIO fdesc) = undefined
cgFDesc (FApp name fdescs) = undefined

data OCaml_Type = OCaml_Int
                | OCaml_Unit
                | OCaml_String
                | OCaml_Char
                | OCaml_List OCaml_Type
                | OCaml_Data [(Int, [OCaml_DataType])]
                deriving (Show)

data OCaml_DataType = Const OCaml_Type
                    | Rec
                    deriving (Show)

ocamlType :: FDesc -> OCaml_Type
ocamlType (FCon ffiType)
  | ffiType == sUN "OCaml_Int" = OCaml_Int
  | ffiType == sUN "OCaml_Unit" = OCaml_Unit
  | ffiType == sUN "OCaml_String" = OCaml_String
  | ffiType == sUN "OCaml_Char" = OCaml_Char
ocamlType (FApp (UN ffiType) params)
  | str ffiType == "OCaml_List" = OCaml_List (ocamlType $ params !! 1)
  | str ffiType == "OCaml_Data" = OCaml_Data (ocamlData $ head params)
ocamlType what = error $ "ocamlType: " ++ show what

ocamlData :: FDesc -> [(Int, [OCaml_DataType])]
ocamlData = (withTags 0 0) . ocamlData'
  where
    ocamlData' :: FDesc -> [[OCaml_DataType]]
    ocamlData' (FApp fn _) | fn == sUN "Nil" = []
    ocamlData' (FApp fn [_,t,ts]) | fn == sUN "::" = ocamlCon t : ocamlData' ts
    ocamlData' what = error $ "ocamlData': oh no: " ++ show what

    withTags :: Int -> Int -> [[OCaml_DataType]] -> [(Int, [OCaml_DataType])]
    withTags _ _ [] = []
    withTags zeroargs someargs ([] : ts) = (zeroargs, []) : withTags (zeroargs + 1) someargs ts
    withTags zeroargs someargs (t : ts) = (someargs, t) : withTags zeroargs (someargs + 1) ts

ocamlCon :: FDesc -> [OCaml_DataType]
ocamlCon (FApp fn _) | fn == sUN "Nil" = []
ocamlCon (FApp fn [_,_,_,t]) | fn == sUN "MkDPair" = [Const $ ocamlType t]
ocamlCon (FApp fn [_,t,ts]) | fn == sUN "::" = ocamlCon t ++ ocamlCon ts
ocamlCon (FApp fn [_,t]) | fn == sUN "Const" = ocamlCon t
ocamlCon (FApp fn _) | fn == sUN "Rec" = [Rec]
ocamlCon what = error $ "ocamlCon: oh no: " ++ show what

toOCaml :: OCaml_Type -> Sexp
toOCaml (OCaml_List t) = S [A "apply", A "$%mklist", toOCaml t]
toOCaml (OCaml_Data d) = mkdata d 
toOCaml _ = S [A "lambda", S [A "$x"], A "$x"]

fromOCaml :: OCaml_Type -> Sexp
fromOCaml (OCaml_List t) = S [A "apply", A "$%unmklist", fromOCaml t]
fromOCaml (OCaml_Data d) = unmkdata d
fromOCaml _ = S [A "lambda", S [A "$x"], A "$x"]

mkdata :: [(Int, [OCaml_DataType])] -> Sexp
mkdata d = S [A"lambda", S [A"$d"], S [A"let", 
             S [A"rec", S [A"$%mkdata",
               S [A"lambda", S [A"$d"], S ([A"switch", A"$d"] ++ mkcases (zip [0..] d))]]],
             S [A"apply", A"$%mkdata", A"$d"]]]

  where

    mkcases :: [(Int, (Int, [OCaml_DataType]))] -> [Sexp]
    mkcases [x] = [S [S [A"tag", KInt 0], mkcons x]]
    mkcases (x : xs) =
      [S [S [A"tag", KInt 0], mkcons x],
          S [S [A"tag", KInt 1],
            S [A"apply", S [A"lambda", S [A"$d"], S ([A"switch", A"$d"] ++ mkcases xs)],
                         S [A"field", KInt 1, A"$d"]]]]
    
    mkcons :: (Int, (Int, [OCaml_DataType])) -> Sexp
    mkcons (idristag, (ocamlint, [])) = KInt ocamlint
    mkcons (idristag, (ocamltag, tys)) =
      S ([A"block", S [A"tag", KInt ocamltag]] ++
        map (\(i,ty) -> S [A"apply", mktype ty, S [A"field", KInt i, S [A"field", KInt 1, A"$d"]]]) (zip [1..] tys))

    mktype :: OCaml_DataType -> Sexp
    mktype (Const ty) =
      S [A"lambda", S [A"$d"], S [A"apply", toOCaml ty, S [A"field", KInt 1, A"$d"]]]
    mktype Rec =
      S [A"lambda", S [A"$d"], S [A"apply", A"$%mkdata", S [A"field", KInt 1, S [A"field", KInt 1, A"$d"]]]]

unmkdata :: [(Int, [OCaml_DataType])] -> Sexp
unmkdata d = S [A"lambda", S [A"$d"], S [A"let", 
               S [A"rec", S [A"$%unmkdata",
                 S [A"lambda", S [A"$d"], S ([A"switch", A"$d"] ++ map unmkcase (zip [0..] d))]]],
               S [A"apply", A"$%unmkdata", A"$d"]]]

  where

    unmkcase :: (Int, (Int, [OCaml_DataType])) -> Sexp
    unmkcase (idristag, (ocamlint, [])) = S [KInt ocamlint, sums idristag (products [])]
    unmkcase (idristag, (ocamltag, tys)) = S [S [A"tag", KInt ocamltag], sums idristag (products $ zip [0..] tys)]
    
    sums :: Int -> Sexp -> Sexp
    sums 0 s = S [A"block", S [A"tag", KInt 0], KInt 0, s]
    sums i s = S [A"block", S [A"tag", KInt 1], KInt 1, sums (i - 1) s]
  
    products :: [(Int, OCaml_DataType)] -> Sexp
    products [] = S [A"block", S [A"tag", KInt 0], KInt 0]
    products ((i,t) : ts) = S [A"block", S [A"tag", KInt 1], KInt 1, unmktype i t, products ts]
  
    unmktype :: Int -> OCaml_DataType -> Sexp
    unmktype i (Const ty) =
      S [A"block", S [A"tag", KInt 0], KInt 0, S [A"apply", fromOCaml ty, S [A"field", KInt i, A"$d"]]]
    unmktype i Rec =
      S [A"block", S [A"tag", KInt 1], KInt 1, S [A"apply", A"$%unmkdata", S [A"field", KInt i, A"$d"]]]


cgSwitch e cases =
  S [A "let", S [scr, cgVar e],
     S $ [A "switch", scr] ++
         map cgTagGroup taggroups ++
         concatMap cgNonTagCase cases]
  where
    scr = A "$%sw"    
    tagcases = concatMap (\c -> case c of
       c@(SConCase lv tag n args body) -> [(tag, c)]
       _ -> []) cases
    taggroups =
      map (\cases -> ((fst $ head cases) `mod` 200, map snd cases)) $
      groupBy ((==) `on` ((`mod` 200) . fst)) $
      sortBy (comparing fst) $ tagcases
    cgTagGroup (tagmod, cases) =
      S [S [A "tag", KInt tagmod], cgTagClass cases]
--    cgTagClass [c] =
--      cgProjections c
    cgTagClass cases =
      S (A "switch" : S [A "field", KInt 0, scr] :
         [S [KInt tag, cgProjections c] | c@(SConCase _ tag _ _ _) <- cases])
    cgProjections (SConCase lv tag n args body) =
      S ([A "let"] ++
         zipWith3 (\v i n -> S [cgVar (Loc v), S [A "field", KInt (i+1), scr]]) [lv..] [0..] args ++
         [cgExp body])
    cgNonTagCase (SConCase _ _ _ _ _) = []
    cgNonTagCase (SConstCase (I n) e) = [S [KInt n, cgExp e]]
    cgNonTagCase (SConstCase (BI n) e) = [S [KInt (fromInteger n), cgExp e]]
    cgNonTagCase (SConstCase (Ch c) e) = [S [KInt (ord c), cgExp e]]
    cgNonTagCase (SConstCase k e) = error $ "unsupported constant selector: " ++ show k
    cgNonTagCase (SDefaultCase e) = [S [A "_", S [A "tag", A "_"], cgExp e]]
    

arithSuffix (ATInt ITNative) = ""
arithSuffix (ATInt ITChar) = ""
arithSuffix (ATInt ITBig) = ".ibig"
arithSuffix s = error $ "unsupported arithmetic type: " ++ show s


stdlib path args = S (A "apply" : S (A "global" : map (A . ('$':)) path) : map cgVar args)

pervasive f args = stdlib ["Pervasives", f] args

cgOp LStrConcat [l, r] =
  S [A "apply", S [A "global", A "$Pervasives", A "$^"], cgVar l, cgVar r]
cgOp LStrCons [c, r] =
  S [A "apply", S [A "global", A "$Pervasives", A "$^"],
     S [A "apply", S [A "global", A "$String", A "$make"],
        KInt 1, cgVar c], cgVar r] -- fixme safety
cgOp LWriteStr [_, str] =
  S [A "apply", S [A "global", A "$Pervasives", A "$print_string"], cgVar str]
cgOp LReadStr [_] = S [A "apply", S [A "global", A "$Pervasives", A "$read_line"], KInt 0]
cgOp (LPlus t) args = S (A ("+" ++ arithSuffix t) : map cgVar args)
cgOp (LMinus t) args = S (A ("-" ++ arithSuffix t) : map cgVar args)
cgOp (LTimes t) args = S (A ("*" ++ arithSuffix t) : map cgVar args)
cgOp (LSRem t) args = S (A ("%" ++ arithSuffix t) : map cgVar args)
cgOp (LEq t) args = S (A ("==" ++ arithSuffix t) : map cgVar args)
cgOp (LSLt t) args = S (A ("<" ++ arithSuffix t) : map cgVar args)
cgOp (LSGt t) args = S (A (">" ++ arithSuffix t) : map cgVar args)
cgOp (LSLe t) args = S (A ("<=" ++ arithSuffix t) : map cgVar args)
cgOp (LSGe t) args = S (A (">=" ++ arithSuffix t) : map cgVar args)
cgOp (LIntStr ITNative) args = pervasive "string_of_int" args
cgOp (LIntStr ITBig) args = stdlib ["Z", "to_string"] args
cgOp (LChInt _) [x] = cgVar x
cgOp (LIntCh _) [x] = cgVar x
cgOp (LSExt _ _) [x] = cgVar x -- FIXME
cgOp (LTrunc _ _) [x] = cgVar x -- FIXME
cgOp (LStrInt ITNative) [x] = pervasive "int_of_string" [x]
cgOp LStrEq args = stdlib ["String", "equal"] args
cgOp LStrLen [x] = S [A "length.byte", cgVar x]
cgOp LStrHead [x] = S [A "load.byte", cgVar x, KInt 0]
cgOp LStrIndex args = S (A "store.byte" : map cgVar args)
cgOp LStrTail [x] = S [A "apply", S [A "global", A "$String", A "$sub"], cgVar x, KInt 1,
                       S [A "-", cgOp LStrLen [x], KInt 1]]
cgOp LStrRev [s] = S [A "apply", A "$%strrev", cgVar s]
cgOp p _ = S [A "apply", S [A "global", A "$Pervasives", A "$failwith"], KStr $ "unimplemented: " ++ show p]


cgConst (I n) = KInt n
cgConst (BI n) = S [A "i.big", A (show n)]
cgConst (Fl x) = error "no floats"
cgConst (Ch i) = KInt (ord i)
cgConst (Str s) = KStr s
cgConst k = error $ "unimplemented constant " ++ show k


