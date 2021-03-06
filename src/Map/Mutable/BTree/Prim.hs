{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module Map.Mutable.BTree.Prim
  ( Node
  , Context(..)
  , lookup
  , insert
  , modifyWithM
  , new
  , foldrWithKey
  , toAscList
  , fromList
  , debugMap
  ) where

import Prelude hiding (lookup)
import Data.Primitive hiding (fromList)
import Data.Primitive.MutVar
import Control.Monad

import Data.Primitive.PrimArray
import Control.Monad.ST

-- data Map s k v = Map
--   !(MutVar s (Node s k v)) -- The actual B Tree
--   !Int -- Degree of B Tree

data Context s = Context
  { contextDegree :: {-# UNPACK #-} !Int
  }

data Node s k v = Node
  !(MutVar s Int) -- current number of keys in this node
  !(MutablePrimArray s k)
  !(Contents s k v)

data Contents s k v
  = ContentsValues !(MutablePrimArray s v)
  | ContentsNodes !(MutableArray s (Node s k v))

new :: (Prim k, Prim v)
  => Context s -- ^ Max number of children per node
  -> ST s (Node s k v)
new (Context degree) = do
  if degree < 3
    then error "Btree.new: max nodes per child cannot be less than 3"
    else return ()
  szRef <- newMutVar 0
  keys <- newPrimArray (degree - 1)
  values <- newPrimArray (degree - 1)
  return (Node szRef keys (ContentsValues values))

lookup :: forall s k v. (Ord k, Prim k, Prim v)
  => Context s -> Node s k v -> k -> ST s (Maybe v)
lookup (Context _) theNode k = go theNode
  where
  go :: Node s k v -> ST s (Maybe v)
  go (Node szRef keys c) = do
    sz <- readMutVar szRef
    case c of
      ContentsValues values -> do
        e <- findIndex keys k sz
        case e of
          Left _ -> return Nothing
          Right ix -> do
            v <- readPrimArray values ix
            return (Just v)
      ContentsNodes nodes -> do
        ix <- findIndexBetween keys k sz
        go =<< readArray nodes ix

data Insert s k v
  = Ok !v
  | Split !(Node s k v) !k !v
    -- ^ The new node that will go to the right,
    --   the key propagated to the parent,
    --   the inserted value.

uninitializedNode :: a
uninitializedNode = error "unitializedNode: this should not be forced, b+ tree implementation has a mistake."

-- minimumKey :: forall s k v. Prim k => Node s k v -> ST s k
-- minimumKey = go
--   where
--   go :: Node s k v -> ST s k
--   go (Node szRef keys c) = do
--     sz <- readMutVar szRef
--     case c of
--       ContentsValues _ -> readPrimArray keys 0
--       ContentsNodes nodes -> go =<< readArray nodes 0

insert :: (Ord k, Prim k, Prim v)
  => Context s
  -> Node s k v
  -> k
  -> v
  -> ST s ()
insert ctx m k v = modifyWithM ctx m k (\_ -> return v) >> return ()

-- | This is provided for completeness but is not something
--   typically useful in producetion code.
toAscList :: forall s k v. (Ord k, Prim k, Prim v)
  => Context s
  -> Node s k v
  -> ST s [(k,v)]
toAscList = foldrWithKey f []
  where
  f :: k -> v -> [(k,v)] -> ST s [(k,v)]
  f k v xs = return ((k,v) : xs)

fromList :: (Ord k, Prim k, Prim v)
  => Context s -> [(k,v)] -> ST s (Node s k v)
fromList ctx xs = do
  m <- new ctx
  forM_ xs $ \(k,v) -> do
    insert ctx m k v
  return m

foldrWithKey :: forall s k v b. (Ord k, Prim k, Prim v)
  => (k -> v -> b -> ST s b)
  -> b
  -> Context s
  -> Node s k v
  -> ST s b
foldrWithKey f b0 (Context _) root = flip go b0 root
  where
  go :: Node s k v -> b -> ST s b
  go (Node szRef keys c) b = do
    sz <- readMutVar szRef
    case c of
      ContentsValues values -> foldrPrimArrayPairs sz f b keys values
      ContentsNodes nodes -> foldrArray (sz + 1) go b nodes

foldrArray :: forall s a b.
     Int -- ^ length of array
  -> (a -> b -> ST s b)
  -> b
  -> MutableArray s a
  -> ST s b
foldrArray len f b0 arr = go (len - 1) b0
  where
  go :: Int -> b -> ST s b
  go !ix !b1 = if ix >= 0
    then do
      a <- readArray arr ix
      b2 <- f a b1
      go (ix - 1) b2
    else return b1

foldrPrimArrayPairs :: forall s k v b. (Ord k, Prim k, Prim v)
  => Int -- ^ length of arrays
  -> (k -> v -> b -> ST s b)
  -> b
  -> MutablePrimArray s k
  -> MutablePrimArray s v
  -> ST s b
foldrPrimArrayPairs len f b0 ks vs = go (len - 1) b0
  where
  go :: Int -> b -> ST s b
  go !ix !b1 = if ix >= 0
    then do
      k <- readPrimArray ks ix
      v <- readPrimArray vs ix
      b2 <- f k v b1
      go (ix - 1) b2
    else return b1

modifyWithM :: forall s k v. (Ord k, Prim k, Prim v)
  => Context s
  -> Node s k v
  -> k
  -> (Maybe v -> ST s v)
  -> ST s (v, Node s k v)
modifyWithM (Context degree) root k alter = do
  ins <- go root
  case ins of
    Ok v -> return (v,root)
    Split rightNode newRootKey v -> do
      let leftNode = root
      newRootSz <- newMutVar 1
      newRootKeys <- newPrimArray (degree - 1)
      writePrimArray newRootKeys 0 newRootKey
      newRootChildren <- newArray degree uninitializedNode
      writeArray newRootChildren 0 leftNode
      writeArray newRootChildren 1 rightNode
      let newRoot = Node newRootSz newRootKeys (ContentsNodes newRootChildren)
      return (v,newRoot)
  where
  go :: Node s k v -> ST s (Insert s k v)
  go (Node szRef keys c) = do
    sz <- readMutVar szRef
    case c of
      ContentsValues values -> do
        e <- findIndex keys k sz
        case e of
          Left gtIx -> do
            v <- alter Nothing
            if sz < degree - 1
              then do
                -- We have enough space
                writeMutVar szRef (sz + 1)
                unsafeInsertPrimArray sz gtIx k keys
                unsafeInsertPrimArray sz gtIx v values
                return (Ok v)
              else do
                -- We do not have enough space. The node must be split.
                let leftSize = div sz 2
                    rightSize = sz - leftSize
                    leftKeys = keys
                    leftValues = values
                if gtIx < leftSize
                  then do
                    rightKeys <- newPrimArray (degree - 1)
                    rightValues <- newPrimArray (degree - 1)
                    rightSzRef <- newMutVar rightSize
                    copyMutablePrimArray rightKeys 0 leftKeys leftSize rightSize
                    copyMutablePrimArray rightValues 0 leftValues leftSize rightSize
                    unsafeInsertPrimArray leftSize gtIx k leftKeys
                    unsafeInsertPrimArray leftSize gtIx v leftValues
                    propagated <- readPrimArray rightKeys 0
                    writeMutVar szRef (leftSize + 1)
                    return (Split (Node rightSzRef rightKeys (ContentsValues rightValues)) propagated v)
                  else do
                    rightKeys <- newPrimArray (degree - 1)
                    rightValues <- newPrimArray (degree - 1)
                    rightSzRef <- newMutVar (rightSize + 1)
                    -- Currently, we're copying from left to right and
                    -- then doing another copy from right to right. We
                    -- might be able to do better. We could do the same number
                    -- of memcpys but copy fewer total elements and not
                    -- have the slowdown caused by overlap.
                    copyMutablePrimArray rightKeys 0 leftKeys leftSize rightSize
                    copyMutablePrimArray rightValues 0 leftValues leftSize rightSize
                    unsafeInsertPrimArray rightSize (gtIx - leftSize) k rightKeys
                    unsafeInsertPrimArray rightSize (gtIx - leftSize) v rightValues
                    propagated <- readPrimArray rightKeys 0
                    writeMutVar szRef leftSize
                    return (Split (Node rightSzRef rightKeys (ContentsValues rightValues)) propagated v)
          Right ix -> do
            v <- readPrimArray values ix
            v' <- alter (Just v)
            writePrimArray values ix v'
            return (Ok v')
      ContentsNodes nodes -> do
        (gtIx,isEq) <- findIndexGte keys k sz
        -- case e of
        --   Right _ -> error "write Right case"
        --   Left gtIx -> do
        node <- readArray nodes (if isEq then gtIx + 1 else gtIx)
        ins <- go node
        case ins of
          Ok v -> return (Ok v)
          Split rightNode propagated v -> if sz < degree - 1
            then do
              unsafeInsertPrimArray sz gtIx propagated keys
              unsafeInsertArray (sz + 1) (gtIx + 1) rightNode nodes
              writeMutVar szRef (sz + 1)
              return (Ok v)
            else do
              let middleIx = div sz 2
                  leftKeys = keys
                  leftNodes = nodes
              middleKey <- readPrimArray keys middleIx
              rightKeys :: MutablePrimArray s k <- newPrimArray (degree - 1)
              rightNodes <- newArray degree uninitializedNode
              rightSzRef <- newMutVar 0 -- this always gets replaced
              let leftSize = middleIx
                  rightSize = sz - leftSize
              if middleIx >= gtIx
                then do
                  copyMutablePrimArray rightKeys 0 leftKeys (leftSize + 1) (rightSize - 1)
                  copyMutableArray rightNodes 0 leftNodes (leftSize + 1) rightSize
                  unsafeInsertPrimArray leftSize gtIx propagated leftKeys
                  unsafeInsertArray (leftSize + 1) (gtIx + 1) rightNode leftNodes
                  writeMutVar szRef (leftSize + 1)
                  writeMutVar rightSzRef (rightSize - 1)
                else do
                  -- Currently, we're copying from left to right and
                  -- then doing another copy from right to right. We can do better.
                  -- There is a similar note further up.
                  copyMutablePrimArray rightKeys 0 leftKeys (leftSize + 1) (rightSize - 1)
                  copyMutableArray rightNodes 0 leftNodes (leftSize + 1) rightSize
                  unsafeInsertPrimArray (rightSize - 1) (gtIx - leftSize - 1) propagated rightKeys
                  unsafeInsertArray rightSize (gtIx - leftSize) rightNode rightNodes
                  writeMutVar szRef leftSize
                  writeMutVar rightSzRef rightSize
              return (Split (Node rightSzRef rightKeys (ContentsNodes rightNodes)) middleKey v)
                  
-- Preconditions:
-- * marr is sorted low to high
-- * sz is less than or equal to the true size of marr
-- The returned value is in the inclusive range [0,sz]
findIndexBetween :: forall s a. (Ord a, Prim a)
  => MutablePrimArray s a -> a -> Int -> ST s Int
findIndexBetween !marr !needle !sz = go 0
  where
  go :: Int -> ST s Int
  go !i = if i < sz
    then do
      a <- readPrimArray marr i
      if a > needle
        then return i
        else go (i + 1)
    else return i -- i should be equal to sz

-- Preconditions:
-- * marr is sorted low to high
-- * sz is less than or equal to the true size of marr
-- The returned value is either
-- * in the inclusive range [0,sz - 1]
-- * the value (-1), indicating that no match was found
findIndex :: forall s a. (Ord a, Prim a)
  => MutablePrimArray s a -> a -> Int -> ST s (Either Int Int)
findIndex !marr !needle !sz = go 0
  where
  go :: Int -> ST s (Either Int Int)
  go !i = if i < sz
    then do
      a <- readPrimArray marr i
      case compare a needle of
        LT -> go (i + 1)
        EQ -> return (Right i)
        GT -> return (Left i)
    else return (Left i)

-- | The second value in the tuple is true when
--   the index match was exact.
findIndexGte :: forall s a. (Ord a, Prim a)
  => MutablePrimArray s a -> a -> Int -> ST s (Int,Bool)
findIndexGte !marr !needle !sz = go 0
  where
  go :: Int -> ST s (Int,Bool)
  go !i = if i < sz
    then do
      a <- readPrimArray marr i
      case compare a needle of
        LT -> go (i + 1)
        EQ -> return (i,True)
        GT -> return (i,False)
    else return (i,False)

-- | Insert an element in the array, shifting the values right 
--   of the index. The array size should be big enough for this
--   shift, this is not checked.
unsafeInsertArray ::
     Int -- ^ Size of the original array
  -> Int -- ^ Index
  -> a -- ^ Value
  -> MutableArray s a -- ^ Array to modify
  -> ST s ()
unsafeInsertArray sz i x marr = do
  copyMutableArray marr (i + 1) marr i (sz - i)
  writeArray marr i x

-- Inserts a value at the designated index,
-- shifting everything after it to the right.
--
-- Example:
-- -----------------------------
-- | a | b | c | d | e | X | X |
-- -----------------------------
-- unsafeInsertPrimArray 5 3 'k' marr
--
unsafeInsertPrimArray ::
     Prim a
  => Int -- ^ Size of the original array
  -> Int -- ^ Index
  -> a -- ^ Value
  -> MutablePrimArray s a -- ^ Array to modify
  -> ST s ()
unsafeInsertPrimArray sz i x marr = do
  copyMutablePrimArray marr (i + 1) marr i (sz - i)
  writePrimArray marr i x


showPairs :: forall s k v. (Show k, Show v, Prim k, Prim v)
  => Int -- size
  -> MutablePrimArray s k
  -> MutablePrimArray s v
  -> ST s [String]
showPairs sz keys values = go 0
  where
  go :: Int -> ST s [String]
  go ix = if ix < sz
    then do
      k <- readPrimArray keys ix
      v <- readPrimArray values ix
      let str = show k ++ ": " ++ show v
      strs <- go (ix + 1)
      return (str : strs)
    else return []

-- | Show the internal structure of a Map, useful for debugging, not exported
debugMap :: forall s k v. (Prim k, Prim v, Show k, Show v)
  => Context s
  -> Node s k v
  -> ST s String
debugMap (Context _) (Node rootSzRef rootKeys rootContents) = do
  rootSz <- readMutVar rootSzRef
  let go :: Int -> Int -> MutablePrimArray s k -> Contents s k v -> ST s [(Int,String)]
      go level sz keys c = case c of
        ContentsValues values -> do
          pairStrs <- showPairs sz keys values
          return (map (\s -> (level,s)) pairStrs)
        ContentsNodes nodes -> do
          pairs <- pairForM sz keys nodes
            $ \k (Node nextSzRef nextKeys nextContents) -> do
              nextSz <- readMutVar nextSzRef
              nextStrs <- go (level + 1) nextSz nextKeys nextContents
              return (nextStrs ++ [(level,show k)]) -- ++ " (Size: " ++ show nextSz ++ ")")])
          -- I think this should always end up being in bounds
          Node lastSzRef lastKeys lastContents <- readArray nodes sz
          lastSz <- readMutVar lastSzRef
          lastStrs <- go (level + 1) lastSz lastKeys lastContents
          -- return (nextStrs ++ [(level,show k)])
          return ([(level, "start")] ++ concat pairs ++ lastStrs)
  allStrs <- go 0 rootSz rootKeys rootContents
  return $ unlines $ map (\(level,str) -> replicate (level * 2) ' ' ++ str) ((0,"root size: " ++ show rootSz) : allStrs)

pairForM :: forall s a b c. Prim a
  => Int 
  -> MutablePrimArray s a 
  -> MutableArray s c
  -> (a -> c -> ST s b)
  -> ST s [b]
pairForM sz marr1 marr2 f = go 0
  where
  go :: Int -> ST s [b]
  go ix = if ix < sz
    then do
      a <- readPrimArray marr1 ix
      c <- readArray marr2 ix
      b <- f a c
      bs <- go (ix + 1)
      return (b : bs)
    else return []

