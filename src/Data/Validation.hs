{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE Safe #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Data types similar to @Data.Either@ that are explicit about failure and success.
module Data.Validation
(
  -- * Data types
  AccValidation
, Validation
, ValidationT(..)
, Validation'
  -- * Prisms
, _Failure
, _Success
  -- * Isomorphisms
, Validate(..)
) where

import Control.Applicative(Applicative((<*>), pure), Alternative((<|>), empty), liftA2, (<$>))
import Control.Lens.Getter((^.))
import Control.Lens.Iso(Swapped(..), Iso, iso)
import Control.Lens.Prism(Prism, prism)
import Control.Lens.Review(( # ))
import Control.Monad(Monad((>>=), return))
import Data.Bifoldable(Bifoldable(bifoldr))
import Data.Bifunctor(Bifunctor(bimap))
import Data.Bitraversable(Bitraversable(bitraverse))
import Data.Data(Data)
import Data.Either(Either(Left, Right))
import Data.Eq(Eq)
import Data.Foldable(Foldable(foldr))
import Data.Function((.), id, flip)
import Data.Functor(Functor(fmap))
import Data.Functor.Alt(Alt((<!>)))
import Data.Functor.Apply(Apply((<.>)))
import Data.Functor.Bind(Bind((>>-)), liftF2)
import Data.Functor.Identity(Identity(Identity))
import Data.Monoid(Monoid(mappend, mempty))
import Data.Ord(Ord)
import Data.Semigroup(Semigroup((<>)))
import Data.Traversable(Traversable(traverse))
import Data.Typeable(Typeable)
import Prelude(Show)

-- $setup
-- >>> import Prelude(Num(..))
-- >>> import Data.Eq(Eq(..))
-- >>> import Data.String(String)
-- >>> import Data.Int(Int)
-- >>> import Test.QuickCheck
-- >>> import Data.Either(either)
-- >>> instance (Arbitrary err, Arbitrary a) => Arbitrary (AccValidation err a) where arbitrary = fmap (either (_Failure #) (_Success #)) arbitrary
-- >>> instance (Arbitrary err, Arbitrary a) => Arbitrary (Validation err a) where arbitrary = fmap (either (_Failure #) (_Success #)) arbitrary
-- >>> instance (Applicative m, Arbitrary err, Arbitrary a) => Arbitrary (ValidationT m err a) where arbitrary = fmap (ValidationT . pure) arbitrary

-- | A value of the type @err@ or @a@, however, the @Applicative@ instance
-- accumulates values. This is witnessed by the @Semigroup@ context on the instance.
-- /Note that there is no Monad such that ap = (<*>)./
--
-- >>> _Success # (+1) <*> _Success # 7 :: AccValidation String Int
-- AccSuccess 8
--
-- >>> _Failure # ["f1"] <*> _Success # 7 :: AccValidation [String] Int
-- AccFailure ["f1"]
--
-- >>> _Success # (+1) <*> _Failure # ["f2"] :: AccValidation [String] Int
-- AccFailure ["f2"]
--
-- >>> _Failure # ["f1"] <*> _Failure # ["f2"] :: AccValidation [String] Int
-- AccFailure ["f1","f2"]
data AccValidation err a =
  AccFailure err
  | AccSuccess a
  deriving (Eq, Ord, Show, Data, Typeable)

instance Functor (AccValidation err) where
  fmap _ (AccFailure e) =
    AccFailure e
  fmap f (AccSuccess a) =
    AccSuccess (f a)

instance Semigroup err => Apply (AccValidation err) where
  AccFailure e1 <.> AccFailure e2 =
    AccFailure (e1 <> e2)
  AccFailure e1 <.> AccSuccess _  =
    AccFailure e1
  AccSuccess _  <.> AccFailure e2 =
    AccFailure e2
  AccSuccess f  <.> AccSuccess a  =
    AccSuccess (f a)

instance Semigroup err => Applicative (AccValidation err) where
  pure =
    AccSuccess
  (<*>) =
    (<.>)

instance Semigroup err => Alt (AccValidation err) where
  AccFailure _ <!> x =
    x
  AccSuccess a <!> _ =
    AccSuccess a

instance (Semigroup err, Monoid err) => Alternative (AccValidation err) where
  AccFailure _ <|> x =
    x
  AccSuccess a <|> _ =
    AccSuccess a
  empty =
    AccFailure mempty

instance Foldable (AccValidation err) where
  foldr f x (AccSuccess a) =
    f a x
  foldr _ x (AccFailure _) =
    x

instance Traversable (AccValidation err) where
  traverse f (AccSuccess a) =
    AccSuccess <$> f a
  traverse _ (AccFailure e) =
    pure (AccFailure e)

instance Bifunctor AccValidation where
  bimap f _ (AccFailure e) =
    AccFailure (f e)
  bimap _ g (AccSuccess a) =
    AccSuccess (g a)

instance Bifoldable AccValidation where
  bifoldr _ g x (AccSuccess a) =
    g a x
  bifoldr f _ x (AccFailure e) =
    f e x

instance Bitraversable AccValidation where
  bitraverse _ g (AccSuccess a) =
    AccSuccess <$> g a
  bitraverse f _ (AccFailure e) =
    AccFailure <$> f e

-- |
--
-- prop> ((x <> y) <> z) == (x <> (y <> z :: AccValidation [String] Int))
instance Semigroup e => Semigroup (AccValidation e a) where
  AccFailure e1 <> AccFailure e2 =
    AccFailure (e1 <> e2)
  AccFailure _ <> AccSuccess a2  =
    AccSuccess a2
  AccSuccess a1  <> AccFailure _ =
    AccSuccess a1
  AccSuccess a1 <> AccSuccess _ =
    AccSuccess a1

-- |
--
-- prop> ((x `mappend` y) `mappend` z) == (x `mappend` (y `mappend` z :: AccValidation [String] Int))
--
-- prop> mempty `mappend` x == (x :: AccValidation [String] Int)
--
-- prop> x `mappend` mempty == (x :: AccValidation [String] Int)
instance Monoid e => Monoid (AccValidation e a) where
  AccFailure e1 `mappend` AccFailure e2 =
    AccFailure (e1 `mappend` e2)
  AccFailure _ `mappend` AccSuccess a2  =
    AccSuccess a2
  AccSuccess a1  `mappend` AccFailure _ =
    AccSuccess a1
  AccSuccess a1 `mappend` AccSuccess _ =
    AccSuccess a1
  mempty =
    AccFailure mempty

-- | A value of the type @err@ or @a@ and isomorphic to @Data.Either@.
--
-- >>> _Success # (+1) <*> _Success # 7 :: Validation String Int
-- Success 8
--
-- >>> _Failure # ["f1"] <*> _Success # 7 :: Validation [String] Int
-- Failure ["f1"]
--
-- >>> _Success # (+1) <*> _Failure # ["f2"] :: Validation [String] Int
-- Failure ["f2"]
--
-- >>> _Failure # ["f1"] <*> _Failure # ["f2"] :: Validation [String] Int
-- Failure ["f1"]
data Validation err a =
  Failure err
  | Success a
  deriving (Eq, Ord, Show, Data, Typeable)

instance Functor (Validation err) where
  fmap _ (Failure e) = Failure e
  fmap f (Success a) = Success (f a)

instance Apply (Validation err) where
  Failure e1 <.> Failure _  =
    Failure e1
  Failure e1 <.> Success _  =
    Failure e1
  Success _  <.> Failure e2 =
    Failure e2
  Success f  <.> Success a  =
    Success (f a)

instance Applicative (Validation err) where
  pure =
    Success
  (<*>) =
    (<.>)

instance Alt (Validation err) where
  Failure _ <!> x =
    x
  Success a <!> _ =
    Success a

instance Monoid err => Alternative (Validation err) where
  Failure _ <|> x =
    x
  Success a <|> _ =
    Success a
  empty =
    Failure mempty

instance Foldable (Validation err) where
  foldr f x (Success a) =
    f a x
  foldr _ x (Failure _) =
    x

instance Traversable (Validation err) where
  traverse f (Success a) =
    Success <$> f a
  traverse _ (Failure e) =
    pure (Failure e)

instance Bifunctor Validation where
  bimap f _ (Failure e) =
    Failure (f e)
  bimap _ g (Success a) =
    Success (g a)

instance Bifoldable Validation where
  bifoldr _ g x (Success a) =
    g a x
  bifoldr f _ x (Failure e) =
    f e x

instance Bitraversable Validation where
  bitraverse _ g (Success a) =
    Success <$> g a
  bitraverse f _ (Failure e) =
    Failure <$> f e

instance Bind (Validation err) where
  Failure e >>- _ =
    Failure e
  Success a >>- f =
    f a

instance Monad (Validation err) where
  return =
    Success
  (>>=) =
    (>>-)

-- | The transformer version of @Validation@.
data ValidationT m err a =
  ValidationT {
    runValidationT :: m (Validation err a)
  }

type Validation' err a =
  ValidationT Identity err a

instance Functor m => Functor (ValidationT m err) where
  fmap f (ValidationT k) =
    ValidationT (fmap (fmap f) k)

instance Apply m => Apply (ValidationT m err) where
  ValidationT f <.> ValidationT a =
    ValidationT (liftF2 (<.>) f a)

instance Applicative m => Applicative (ValidationT m err) where
  pure =
    ValidationT . pure . pure
  ValidationT f <*> ValidationT a =
    ValidationT (liftA2 (<*>) f a)

instance (Functor m, Monad m) => Alt (ValidationT m err) where
  ValidationT x <!> ValidationT y =
    ValidationT (x >>= \q -> case q of
      Failure _ -> y
      Success a -> return (Success a))

instance (Applicative m, Monad m, Monoid err) => Alternative (ValidationT m err) where
  ValidationT x <|> ValidationT y =
    ValidationT (x >>= \q -> case q of
      Failure _ -> y
      Success a -> return (Success a))
  empty =
    ValidationT (pure (Failure mempty))

instance Foldable m => Foldable (ValidationT m err) where
  foldr f z (ValidationT x) =
    foldr (flip (foldr f)) z x

instance Traversable m => Traversable (ValidationT m err) where
  traverse f (ValidationT x) =
      ValidationT <$> traverse (traverse f) x

instance Functor m => Bifunctor (ValidationT m) where
  bimap f g (ValidationT x) =
    ValidationT (fmap (bimap f g) x)

instance Foldable m => Bifoldable (ValidationT m) where
  bifoldr f g z (ValidationT x) =
    foldr (flip (bifoldr f g)) z x

instance Traversable m => Bitraversable (ValidationT m) where
  bitraverse f g (ValidationT x) =
    ValidationT <$> traverse (bitraverse f g) x

instance (Apply m, Monad m) => Bind (ValidationT m err) where
  ValidationT v >>- f =
    ValidationT (v >>= \w -> case w of
                               Failure e -> return (Failure e)
                               Success a -> runValidationT (f a))

instance Monad m => Monad (ValidationT m err) where
  return =
    ValidationT . return . pure
  ValidationT v >>= f =
    ValidationT (v >>= \w -> case w of
                               Failure e -> return (Failure e)
                               Success a -> runValidationT (f a))

class Validate f where
  _Validation ::
    Iso (f e a) (f g b) (Validation e a) (Validation g b)
  _Validation' ::
    Iso (f e a) (f g b) (Validation' e a) (Validation' g b)
  _Validation' =
    iso
      (\x -> ValidationT (Identity (x ^. _Validation)))
      (\(ValidationT (Identity x)) -> _Validation # x)
  _AccValidation ::
    Iso (f e a) (f g b) (AccValidation e a) (AccValidation g b)
  _AccValidation =
    iso
      (\x -> case x ^. _Validation of
               Failure e -> AccFailure e
               Success a -> AccSuccess a)
      (\x -> _Validation # case x of
                             AccFailure e -> Failure e
                             AccSuccess a -> Success a)
  _Either ::
    Iso (f e a) (f g b) (Either e a) (Either g b)
  _Either =
    iso
      (\x -> case x ^. _Validation of
               Failure e -> Left e
               Success a -> Right a)
      (\x -> _Validation # case x of
                             Left e -> Failure e
                             Right a -> Success a)

instance Validate Validation where
  _Validation =
    iso
      id
      id
instance Validate AccValidation where
  _Validation =
    iso
      (\x -> case x of
               AccFailure e -> Failure e
               AccSuccess a -> Success a)
      (\x -> case x of
               Failure e -> AccFailure e
               Success a -> AccSuccess a)
  _AccValidation =
    iso 
      id
      id

instance Validate Either where
  _Validation =
    iso
      (\x -> case x of
               Left e -> Failure e
               Right a -> Success a)
      (\x -> case x of
               Failure e -> Left e
               Success a -> Right a)
  _Either =
    iso 
      id
      id

_Failure ::
  Validate f =>
  Prism (f e1 a) (f e2 a) e1 e2
_Failure =
  prism
    (\x -> _Either # Left x)
    (\x -> case x ^. _Either of
             Left e -> Right e
             Right a -> Left (_Either # Right a))

_Success ::
  Validate f =>
  Prism (f e a) (f e b) a b
_Success =
  prism
    (\x -> _Either # Right x)
    (\x -> case x ^. _Either of
             Left e -> Left (_Either # Left e)
             Right a -> Right a)

instance Swapped AccValidation where
  swapped =
    iso
      (\v -> case v of
               AccFailure e -> AccSuccess e
               AccSuccess a -> AccFailure a)
      (\v -> case v of
               AccFailure a -> AccSuccess a
               AccSuccess e -> AccFailure e)

instance Swapped Validation where
  swapped =
    iso
      (\v -> case v of
               Failure e -> Success e
               Success a -> Failure a)
      (\v -> case v of
               Failure a -> Success a
               Success e -> Failure e)

instance Functor f => Swapped (ValidationT f) where
  swapped =
    iso
      (\(ValidationT x) -> ValidationT (fmap (swapped # ) x))
      (\(ValidationT x) -> ValidationT (fmap (swapped # ) x))
