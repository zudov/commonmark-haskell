{-# LANGUAGE LambdaCase   #-}
{-# LANGUAGE TypeFamilies #-}
module Text.CommonMark.ParserCombinators (
    Position(..)
  , Parser
  , parse
  , parseWithUnconsumed
  , (<?>)
  , satisfy
  , choice
  , withConsumed
  , consumedBy
  , peekChar
  , peekLastChar
  , notAfter
  , inClass
  , notInClass
  , endOfInput
  , char
  , anyChar
  , getPosition
  , setPosition
  , takeWhile
  , takeTill
  , takeWhile1
  , takeText
  , skip
  , skipWhile
  , skipWhile1
  , string
  , scan
  , lookAhead
  , notFollowedBy
  , option
  , foldP
  , many1
  , manyTill
  , many1Till
  , sepBy1
  , sepEndBy1
  , sepStartEndBy1
  , skipMany
  , skipMany1
  , count
  , discard
  , discardOpt
  , decimal
  , hexadecimal
  ) where
import           Control.Applicative
import           Control.Monad
import           Data.Bits           (Bits, shiftL, (.|.))
import           Data.Char           (ord)
import qualified Data.Set            as Set
import           Data.String
import           Data.Text           (Text)
import qualified Data.Text           as T
import           Prelude             hiding (takeWhile)

data Position = Position { line   :: Int
                         , column :: Int
                         , point  :: Int
                         }
     deriving (Ord, Eq)

instance Show Position where
  show (Position ln cn pn) =
    concat ["line ", show ln, " column ", show cn, " point ", show pn]

-- the String indicates what the parser was expecting
data ParseError = ParseError Position String deriving Show

data ParserState = ParserState { subject  :: Text
                               , position :: Position
                               , lastChar :: Maybe Char
                               }

advance :: ParserState -> Text -> ParserState
advance = T.foldl' go
  where go :: ParserState -> Char -> ParserState
        go st c = st{ subject = T.drop 1 (subject st)
                    , position = case c of
                        '\n' -> Position { line = line (position st) + 1
                                         , column = 1
                                         , point = point (position st) + 1
                                         }
                        _    -> Position { line   = line   (position st)
                                         , column = column (position st) + 1
                                         , point  = point (position st) + 1
                                         }
                    , lastChar = Just c }

newtype Parser a = Parser {
  evalParser :: ParserState -> Either ParseError (ParserState, a)
  }

-- | Returns the text that was consumed by a parser alongside with its result
withConsumed :: Parser a -> Parser (a,Text)
withConsumed p = Parser $ \st ->
    case (evalParser p) st of
        Left err -> Left err
        Right (st', res) ->
            let consumedLength = point (position st') - point (position st)
            in Right (st', (res, T.take consumedLength (subject st)))

consumedBy :: Parser a -> Parser Text
consumedBy = fmap snd . withConsumed

instance Functor Parser where
  fmap f (Parser g) = Parser $ \st ->
    case g st of
         Right (st', x) -> Right (st', f x)
         Left e         -> Left e
  {-# INLINE fmap #-}

instance Applicative Parser where
  pure x = Parser $ \st -> Right (st, x)
  (Parser f) <*> (Parser g) = Parser $ \st ->
    case f st of
         Left e         -> Left e
         Right (st', h) -> case g st' of
                                Right (st'', x) -> Right (st'', h x)
                                Left e          -> Left e
  {-# INLINE pure #-}
  {-# INLINE (<*>) #-}

instance Alternative Parser where
  empty = Parser $ \st -> Left $ ParseError (position st) "(empty)"
  (Parser f) <|> (Parser g) = Parser $ \st ->
    case f st of
         Right res                 -> Right res
         Left (ParseError pos msg) ->
           case g st of
             Right res                   -> Right res
             Left (ParseError pos' msg') -> Left $
               case () of
                  -- return error for farthest match
                  _ | pos' > pos  -> ParseError pos' msg'
                    | pos' < pos  -> ParseError pos msg
                    | otherwise {- pos' == pos -}
                                  -> ParseError pos (msg ++ " or " ++ msg')
  {-# INLINE empty #-}
  {-# INLINE (<|>) #-}

instance Monad Parser where
  return x = Parser $ \st -> Right (st, x)
  fail e = Parser $ \st -> Left $ ParseError (position st) e
  p >>= g = Parser $ \st ->
    case evalParser p st of
         Left e        -> Left e
         Right (st',x) -> evalParser (g x) st'
  {-# INLINE return #-}
  {-# INLINE (>>=) #-}

instance MonadPlus Parser where
  mzero = Parser $ \st -> Left $ ParseError (position st) "(mzero)"
  mplus p1 p2 = Parser $ \st ->
    case evalParser p1 st of
         Right res  -> Right res
         Left _     -> evalParser p2 st
  {-# INLINE mzero #-}
  {-# INLINE mplus #-}

instance (a ~ Text) => IsString (Parser a) where
  fromString = string . T.pack


(<?>) :: Parser a -> String -> Parser a
p <?> msg = Parser $ \st ->
  let startpos = position st in
  case evalParser p st of
       Left (ParseError _ _) ->
           Left $ ParseError startpos msg
       Right r                 -> Right r
{-# INLINE (<?>) #-}
infixl 5 <?>

parse :: Parser a -> Text -> Either ParseError a
parse p t =
  fmap snd $ evalParser p ParserState{ subject  = t
                                     , position = Position 1 1 1
                                     , lastChar = Nothing }

parseWithUnconsumed :: Parser a -> Text -> Either ParseError (a,Text)
parseWithUnconsumed p t = fmap (\(st,res) -> (res, subject st))
                        $ evalParser p ParserState { subject = t
                                                   , position = Position 1 1 1
                                                   , lastChar = Nothing }

failure :: ParserState -> String -> Either ParseError (ParserState, a)
failure st msg = Left $ ParseError (position st) msg
{-# INLINE failure #-}

success :: ParserState -> a -> Either ParseError (ParserState, a)
success st x = Right (st, x)
{-# INLINE success #-}

satisfy :: (Char -> Bool) -> Parser Char
satisfy f = Parser g
  where g st = case T.uncons (subject st) of
                    Just (c, _) | f c ->
                         success (advance st (T.singleton c)) c
                    _ -> failure st "character meeting condition"
{-# INLINE satisfy #-}

choice :: Alternative f => [f a] -> f a
choice = foldr (<|>) empty

peekChar :: Parser (Maybe Char)
peekChar = Parser $ \st ->
             case T.uncons (subject st) of
                  Just (c, _) -> success st (Just c)
                  Nothing     -> success st Nothing
{-# INLINE peekChar #-}

peekLastChar :: Parser (Maybe Char)
peekLastChar = Parser $ \st -> success st (lastChar st)
{-# INLINE peekLastChar #-}

notAfter :: (Char -> Bool) -> Parser ()
notAfter f = do
  mbc <- peekLastChar
  case mbc of
       Nothing -> return ()
       Just c  -> if f c then mzero else return ()

-- low-grade version of attoparsec's:
charClass :: String -> Set.Set Char
charClass = Set.fromList . go
    where go (a:'-':b:xs) = [a..b] ++ go xs
          go (x:xs) = x : go xs
          go _ = ""
{-# INLINE charClass #-}

inClass :: String -> Char -> Bool
inClass s c = c `Set.member` s'
  where s' = charClass s
{-# INLINE inClass #-}

notInClass :: String -> Char -> Bool
notInClass s = not . inClass s
{-# INLINE notInClass #-}

endOfInput :: Parser ()
endOfInput = Parser $ \st ->
  if T.null (subject st)
     then success st ()
     else failure st "end of input"
{-# INLINE endOfInput #-}

char :: Char -> Parser Char
char c = satisfy (== c)
{-# INLINE char #-}

anyChar :: Parser Char
anyChar = satisfy (const True)
{-# INLINE anyChar #-}

getPosition :: Parser Position
getPosition = Parser $ \st -> success st (position st)
{-# INLINE getPosition #-}

-- note: this does not actually change the position in the subject;
-- it only changes what column counts as column N.  It is intended
-- to be used in cases where we're parsing a partial line but need to
-- have accurate column information.
setPosition :: Position -> Parser ()
setPosition pos = Parser $ \st -> success st{ position = pos } ()
{-# INLINE setPosition #-}

takeWhile :: (Char -> Bool) -> Parser Text
takeWhile f = Parser $ \st ->
  let t = T.takeWhile f (subject st) in
  success (advance st t) t
{-# INLINE takeWhile #-}

takeTill :: (Char -> Bool) -> Parser Text
takeTill f = takeWhile (not . f)
{-# INLINE takeTill #-}

takeWhile1 :: (Char -> Bool) -> Parser Text
takeWhile1 f = Parser $ \st ->
  case T.takeWhile f (subject st) of
       t | T.null t  -> failure st "characters satisfying condition"
         | otherwise -> success (advance st t) t
{-# INLINE takeWhile1 #-}

takeText :: Parser Text
takeText = Parser $ \st ->
  let t = subject st in
  success (advance st t) t
{-# INLINE takeText #-}

skip :: (Char -> Bool) -> Parser ()
skip f = Parser $ \st ->
  case T.uncons (subject st) of
       Just (c,_) | f c -> success (advance st (T.singleton c)) ()
       _                -> failure st "character satisfying condition"
{-# INLINE skip #-}

-- | A folding parser
foldP :: (b -> a -> Parser (Maybe b))
      -> Parser a -- ^ A parser that supplies more input
      -> b -- ^ Initial value
      -> Parser b
foldP f p b0 = p >>= go b0
  where go b1 a = f b1 a >>= \case Nothing -> pure b1
                                   Just b2 -> p >>= go b2

{-# INLINE foldP #-}

skipWhile :: (Char -> Bool) -> Parser ()
skipWhile f = Parser $ \st ->
  let t' = T.takeWhile f (subject st) in
  success (advance st t') ()
{-# INLINE skipWhile #-}

skipWhile1 :: (Char -> Bool) -> Parser ()
skipWhile1 f = Parser $ \st ->
  case T.takeWhile f (subject st) of
       t' | T.null t' -> failure st "characters satisfying condition"
          | otherwise -> success (advance st t') ()
{-# INLINE skipWhile1 #-}

string :: Text -> Parser Text
string s = Parser $ \st ->
  if s `T.isPrefixOf` (subject st)
     then success (advance st s) s
     else failure st "string"
{-# INLINE string #-}

scan :: s -> (s -> Char -> Maybe s) -> Parser Text
scan s0 f = Parser $ go s0 []
  where go s cs st =
         case T.uncons (subject st) of
               Nothing        -> finish st cs
               Just (c, _)    -> case f s c of
                                  Just s' -> go s' (c:cs)
                                              (advance st (T.singleton c))
                                  Nothing -> finish st cs
        finish st cs =
            success st (T.pack (reverse cs))
{-# INLINE scan #-}

lookAhead :: Parser a -> Parser a
lookAhead p = Parser $ \st ->
  case evalParser p st of
       Right (_,x) -> success st x
       Left _      -> failure st "lookAhead"
{-# INLINE lookAhead #-}

notFollowedBy :: Parser a -> Parser ()
notFollowedBy p = Parser $ \st ->
  case evalParser p st of
       Right (_,_) -> failure st "notFollowedBy"
       Left _      -> success st ()
{-# INLINE notFollowedBy #-}

-- combinators (most definitions borrowed from attoparsec)

option :: Alternative f => a -> f a -> f a
option x p = p <|> pure x
{-# INLINE option #-}

discard :: Applicative f => f a -> f ()
discard p = p *> pure ()

discardOpt :: Alternative f => f a -> f ()
discardOpt p = option () (discard p)

many1 :: Alternative f => f a -> f [a]
many1 p = liftA2 (:) p (many p)
{-# INLINE many1 #-}

many1Till :: Alternative f => f a -> f b -> f [a]
many1Till p end = liftA2 (:) p go
  where go = (end *> pure []) <|> liftA2 (:) p go
{-# INLINE many1Till #-}

manyTill :: Alternative f => f a -> f b -> f [a]
manyTill p end = go
  where go = (end *> pure []) <|> liftA2 (:) p go
{-# INLINE manyTill #-}

sepBy1 :: Alternative f => f a -> f s -> f [a]
sepBy1 p s = go
    where go = liftA2 (:) p ((s *> go) <|> pure [])

sepEndBy1 :: Alternative f => f a -> f s -> f [a]
sepEndBy1 p s = sepBy1 p s <* s

sepStartEndBy1 :: Alternative f => f a -> f s -> f [a]
sepStartEndBy1 p s = s *> sepBy1 p s <* s

skipMany :: Alternative f => f a -> f ()
skipMany p = go
  where go = (p *> go) <|> pure ()
{-# INLINE skipMany #-}

skipMany1 :: Alternative f => f a -> f ()
skipMany1 p = p *> skipMany p
{-# INLINE skipMany1 #-}

count :: Monad m => Int -> m a -> m [a]
count n p = sequence (replicate n p)
{-# INLINE count #-}

-- | Parse and decode an unsigned decimal number.
decimal :: Integral a => Parser a
decimal = T.foldl' step 0 `fmap` takeWhile1 isDecimal
  where step a c = a * 10 + fromIntegral (ord c - 48)

isDecimal :: Char -> Bool
isDecimal c = c >= '0' && c <= '9'
{-# INLINE isDecimal #-}

hexadecimal :: (Integral a, Bits a) => Parser a
hexadecimal = T.foldl' step 0 `fmap` takeWhile1 isHexDigit
  where
    isHexDigit c = (c >= '0' && c <= '9') ||
                   (c >= 'a' && c <= 'f') ||
                   (c >= 'A' && c <= 'F')
    step a c | w >= 48 && w <= 57  = (a `shiftL` 4) .|. fromIntegral (w - 48)
             | w >= 97             = (a `shiftL` 4) .|. fromIntegral (w - 87)
             | otherwise           = (a `shiftL` 4) .|. fromIntegral (w - 55)
      where w = ord c
