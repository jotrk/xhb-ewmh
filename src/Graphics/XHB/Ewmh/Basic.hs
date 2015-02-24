{-# OPTIONS_GHC -fno-warn-orphans #-}

{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ConstraintKinds #-}

module Graphics.XHB.Ewmh.Basic
    where
    -- ( module Graphics.XHB.Ewmh.Types
    -- -- , Utf8String(..)
    -- , runEwmhT
    -- , atomToXidLike
    -- , simpleGetProperty
    -- , simpleChangeProperty
    -- -- , getString
    -- -- , getUtf8String
    -- -- , ewmhRequest
    -- -- , changeNetWmState
    -- -- , netActiveWindow
    -- -- , getNetActiveWindow
    -- -- , netRestackWindow
    -- -- , netMoveResizeWindow
    -- ) where

import qualified Data.HashMap.Lazy as M
import Data.Bits ((.|.), shiftL)
import Data.Word (Word32)
import Data.Maybe (isJust, catMaybes, fromMaybe)
import Control.Monad (join, void)
import Control.Monad.Except (ExceptT(..), runExceptT)
import Control.Monad.State (gets)
import Control.Applicative (Applicative(..), (<$>))
import Control.Monad.IO.Class (MonadIO(..))
import Control.Monad.Trans.Maybe (MaybeT(..))

import Foreign.C (CChar(..))
import Graphics.XHB (Connection, SomeError, WINDOW, ATOM, XidLike, Atom(..))
import Graphics.XHB (GetProperty(..), ChangeProperty(..))
import Graphics.XHB (SendEvent(..), ClientMessageEvent(..), ClientMessageData(..))
import Graphics.XHB (PropMode(..), EventMask(..), Time(..))
import qualified Graphics.XHB as X
import Graphics.XHB.Atom
import Graphics.XHB.Ewmh.Bits
import Graphics.XHB.Ewmh.Atoms
import Graphics.XHB.Ewmh.Types
import Graphics.XHB.Ewmh.Serialize

instance XidLike Atom where
    toXid a = X.toXid (X.toValue a :: Word32)
    fromXid a = X.fromValue (X.fromXid a :: Word32)

class PropertyType t where
    toPropertyType :: MonadEwmh m => t -> m ATOM

instance PropertyType Atom where
    toPropertyType = return . X.fromXid . X.toXid

instance PropertyType UTF8_STRING where
    toPropertyType = unsafeLookupATOM

type BasicEwmhCtx m = (Applicative m, MonadIO m, MonadEwmh m)

type Prop p t r m = (AtomLike p, PropertyType t, Serialize r, BasicEwmhCtx m)

type Request p d m = (AtomLike p, Serialize d, BasicEwmhCtx m)

eitherToExcept :: Monad m => Either e a -> ExceptT e m a
eitherToExcept = ExceptT . return

dump :: Monad m => AtomT m [AtomName]
dump = AtomT $ gets (map atomName . M.keys . fst)

runEwmhT :: (MonadIO m, Applicative m)
         => Connection -> EwmhT m a -> m (Either SomeError a)
runEwmhT c = runAtomT
    . fmap (join . join . join . join)
    . seedAtoms c utf8
    . seedAtoms c ewmh
    . seedAtoms c states
    . seedAtoms c actions
    . seedAtoms c types
    where
    utf8    = [UTF8_STRING]
    ewmh    = [NET_SUPPORTED .. NET_WM_FULL_PLACEMENT]
    states  = [NET_WM_STATE_MODAL .. NET_WM_STATE_FOCUSED]
    actions = [NET_WM_ACTION_MOVE .. NET_WM_ACTION_BELOW]
    types   = [NET_WM_WINDOW_TYPE_DESKTOP .. NET_WM_WINDOW_TYPE_NORMAL]

getProp :: Prop p t r m => Connection -> WINDOW -> p -> t -> m (Either SomeError r)
getProp c w p t = runExceptT $ do
    ap <- unsafeLookupATOM p
    at <- toPropertyType t
    fmap fromReply . eitherToExcept =<< getPropertyReply (request ap at)
    where
    fromReply = fromBytes . X.value_GetPropertyReply
    getPropertyReply req = liftIO $ X.getProperty c req >>= X.getReply
    request ap at = MkGetProperty
        { delete_GetProperty = False
        , window_GetProperty = w
        , property_GetProperty = ap
        , type_GetProperty = at
        , long_offset_GetProperty = 0
        , long_length_GetProperty = maxBound
        }

setProp :: Prop p t r m => Connection -> WINDOW -> p -> t -> r -> m ()
setProp c w p t r = do
    ap <- unsafeLookupATOM p
    at <- toPropertyType t
    liftIO . X.changeProperty c $ request ap at
    where
    values = toBytes r
    request ap at = MkChangeProperty
        { mode_ChangeProperty = PropModeReplace
        , window_ChangeProperty = w
        , property_ChangeProperty = ap
        , type_ChangeProperty = at
        , format_ChangeProperty = 8
        , data_len_ChangeProperty = fromIntegral $ length values
        , data_ChangeProperty = values
        }

getRootProp :: Prop p t r m => Connection -> p -> t -> m (Either SomeError r)
getRootProp c = getProp c (X.getRoot c)

setRootProp :: Prop p t r m => Connection -> p -> t -> r -> m ()
setRootProp c = setProp c (X.getRoot c)

hoistMaybe :: Monad m => Maybe a -> MaybeT m a
hoistMaybe = MaybeT . return

-- | Send an Ewmh request for `WINDOW` to the root window
sendRequest :: Request p d m => Connection -> WINDOW -> p -> d -> m ()
sendRequest c w a d = void . runMaybeT $ do
    lookupATOM a >>= hoistMaybe >>= send
    where
    send = liftIO . X.sendEvent c . request (X.getRoot c) . serializeEvent

    serializeEvent = map (CChar . fromIntegral) . toBytes . event

    event typ = MkClientMessageEvent
        { format_ClientMessageEvent = 32
        , window_ClientMessageEvent = w
        , type_ClientMessageEvent = typ
        , data_ClientMessageEvent = ClientData8 $ toBytes d
        }

    request win raw = MkSendEvent
        { propagate_SendEvent = False
        , destination_SendEvent = win
        , event_mask_SendEvent = [ EventMaskSubstructureNotify
                                 , EventMaskSubstructureRedirect
                                 ]
        , event_SendEvent = raw
        }

----------------------------
-- Root Window Properties --
----------------------------

getNetSupported :: BasicEwmhCtx m => Connection -> m (Either SomeError NetSupported)
getNetSupported c = runExceptT $ do
    atomids <- mapM lookupAtomId
        =<< eitherToExcept
        =<< getRootProp c NET_SUPPORTED AtomATOM
    return $ NetSupported (atoms atomids) (states atomids) (actions atomids) (types atomids)
    where
    -- yeah..
    atoms   = catMaybes . map fromAtom . catMaybes
    states  = catMaybes . map fromAtom . catMaybes
    actions = catMaybes . map fromAtom . catMaybes
    types   = catMaybes . map fromAtom . catMaybes

setNetSupported :: BasicEwmhCtx m => Connection -> NetSupported -> m ()
setNetSupported c ns = do
    state     <- unsafeLookupATOM NET_WM_STATE
    types     <- unsafeLookupATOM NET_WM_WINDOW_TYPE
    actions   <- unsafeLookupATOM NET_WM_ALLOWED_ACTIONS

    atoms     <- mapM unsafeLookupATOM (ewmhAtoms ns)
    atoms'    <- insertAt state   atoms   <$> mapM unsafeLookupATOM (netWmStates ns)
    atoms''   <- insertAt types   atoms'  <$> mapM unsafeLookupATOM (netWmWindowTypes ns)
    atoms'''  <- insertAt actions atoms'' <$> mapM unsafeLookupATOM (netWmAllowedActions ns)

    setRootProp c NET_SUPPORTED AtomATOM atoms'''

    where
    insertAt :: Eq t => t -> [t] -> [t] -> [t]
    insertAt _ [] _      = []
    insertAt a (x:xs) as | a == x    = x : as ++ xs
                         | otherwise = x : insertAt a xs as

getNetClientList :: BasicEwmhCtx m => Connection -> m (Either SomeError [WINDOW])
getNetClientList c = getRootProp c NET_CLIENT_LIST AtomWINDOW

setNetClientList :: BasicEwmhCtx m => Connection -> [WINDOW] -> m ()
setNetClientList c = setRootProp c NET_CLIENT_LIST AtomWINDOW

getNetClientListStacking :: BasicEwmhCtx m => Connection -> m (Either SomeError [WINDOW])
getNetClientListStacking c = getRootProp c NET_CLIENT_LIST_STACKING AtomWINDOW

setNetClientListStacking :: BasicEwmhCtx m => Connection -> [WINDOW] -> m ()
setNetClientListStacking c = setRootProp c NET_CLIENT_LIST_STACKING AtomWINDOW

getNetNumberOfDesktops :: BasicEwmhCtx m => Connection -> m (Either SomeError Word32)
getNetNumberOfDesktops c = getRootProp c NET_NUMBER_OF_DESKTOPS AtomCARDINAL

setNetNumberOfDesktops :: BasicEwmhCtx m => Connection -> Word32 -> m ()
setNetNumberOfDesktops c = setRootProp c NET_NUMBER_OF_DESKTOPS AtomCARDINAL

getNetDesktopGeometry :: BasicEwmhCtx m => Connection -> m (Either SomeError (Word32, Word32))
getNetDesktopGeometry c = getRootProp c NET_DESKTOP_GEOMETRY AtomCARDINAL

setNetDesktopGeometry :: BasicEwmhCtx m => Connection -> (Word32, Word32) -> m ()
setNetDesktopGeometry c = setRootProp c NET_DESKTOP_GEOMETRY AtomCARDINAL

getNetDesktopViewport :: BasicEwmhCtx m => Connection -> m (Either SomeError [(Word32, Word32)])
getNetDesktopViewport c = getRootProp c NET_DESKTOP_VIEWPORT AtomCARDINAL

setNetDesktopViewport :: BasicEwmhCtx m => Connection -> [(Word32, Word32)] -> m ()
setNetDesktopViewport c = setRootProp c NET_DESKTOP_VIEWPORT AtomCARDINAL

getNetCurrentDesktop :: BasicEwmhCtx m => Connection -> m (Either SomeError Word32)
getNetCurrentDesktop c = getRootProp c NET_CURRENT_DESKTOP AtomCARDINAL

setNetCurrentDesktop :: BasicEwmhCtx m => Connection -> Word32 -> m ()
setNetCurrentDesktop c = setRootProp c NET_CURRENT_DESKTOP AtomCARDINAL

getNetDesktopNames :: BasicEwmhCtx m => Connection -> m (Either SomeError [String])
getNetDesktopNames c = getProp c (X.getRoot c) NET_DESKTOP_NAMES UTF8_STRING

setNetDesktopNames :: BasicEwmhCtx m => Connection -> [String] -> m ()
setNetDesktopNames c = setRootProp c NET_DESKTOP_NAMES UTF8_STRING

getActiveWindow :: BasicEwmhCtx m => Connection -> m (Either SomeError WINDOW)
getActiveWindow c = getRootProp c NET_ACTIVE_WINDOW AtomWINDOW

setActiveWindow :: BasicEwmhCtx m => Connection -> WINDOW -> m ()
setActiveWindow c = setRootProp c NET_ACTIVE_WINDOW AtomWINDOW

getNetWorkarea :: BasicEwmhCtx m => Connection -> m (Either SomeError (Word32, Word32, Word32, Word32))
getNetWorkarea c = getRootProp c NET_WORKAREA AtomCARDINAL

setNetWorkarea :: BasicEwmhCtx m => Connection -> (Word32, Word32, Word32, Word32) -> m ()
setNetWorkarea c = setRootProp c NET_WORKAREA AtomCARDINAL

getNetSupportingWmCheck :: BasicEwmhCtx m => Connection -> m (Either SomeError WINDOW)
getNetSupportingWmCheck c = getRootProp c NET_SUPPORTING_WM_CHECK AtomWINDOW

setNetSupportingWmCheck :: BasicEwmhCtx m => Connection -> WINDOW -> m ()
setNetSupportingWmCheck c = setRootProp c NET_SUPPORTING_WM_CHECK AtomWINDOW

getNetVirtualRoots :: BasicEwmhCtx m => Connection -> m (Either SomeError [WINDOW])
getNetVirtualRoots c = getRootProp c NET_VIRTUAL_ROOTS AtomWINDOW

setNetVirtualRoots :: BasicEwmhCtx m => Connection -> [WINDOW] -> m ()
setNetVirtualRoots c = setRootProp c NET_VIRTUAL_ROOTS AtomWINDOW

getNetDesktopLayout :: BasicEwmhCtx m => Connection -> m (Either SomeError NetDesktopLayout)
getNetDesktopLayout conn = getRootProp conn NET_DESKTOP_LAYOUT AtomCARDINAL

setNetDesktopLayout :: BasicEwmhCtx m => Connection -> NetDesktopLayout -> m ()
setNetDesktopLayout c = setRootProp c NET_DESKTOP_LAYOUT AtomCARDINAL

getNetShowingDesktop :: BasicEwmhCtx m => Connection -> m (Either SomeError Word32)
getNetShowingDesktop c = getRootProp c NET_SHOWING_DESKTOP AtomCARDINAL

setNetShowingDesktop :: BasicEwmhCtx m => Connection -> Word32 -> m ()
setNetShowingDesktop c = setRootProp c NET_SHOWING_DESKTOP AtomCARDINAL

--------------------------------
-- Other Root Window Messages --
--------------------------------

requestNetCloseWindow :: BasicEwmhCtx m => Connection -> WINDOW -> SourceIndication -> m ()
requestNetCloseWindow c w si = do
    sendRequest c w NET_CLOSE_WINDOW ([X.toValue TimeCurrentTime, X.toValue si] :: [Word32])

requestNetMoveresizeWindow :: BasicEwmhCtx m
                           => Connection -> WINDOW -> NetMoveresizeWindow -> m ()
requestNetMoveresizeWindow c w mr = sendRequest c w NET_MOVERESIZE_WINDOW values
    where
    x      = netMoveresizeWindow_x mr
    y      = netMoveresizeWindow_y mr
    width  = fromIntegral <$> netMoveresizeWindow_width mr
    height = fromIntegral <$> netMoveresizeWindow_height mr

    sourceIndicationBit = case netMoveresizeWindow_sourceIndication mr of
        SourceApplication -> 12
        SourcePager       -> 13
        _                 -> 0

    gravityBit          = X.toValue $ netMoveresizeWindow_gravity mr
    xBit                = if isJust x      then shiftL 1 8  else 0
    yBit                = if isJust y      then shiftL 1 9  else 0
    widthBit            = if isJust width  then shiftL 1 10 else 0
    heightBit           = if isJust height then shiftL 1 11 else 0

    flags = foldr (.|.) 0 [gravityBit, xBit, yBit, widthBit, heightBit, sourceIndicationBit]

    values = [flags, fromMaybe 0 x, fromMaybe 0 y, fromMaybe 0 width, fromMaybe 0 height]

requestNetWmMoveresize :: BasicEwmhCtx m => Connection -> WINDOW -> NetWmMoveresize -> m ()
requestNetWmMoveresize c w mr = do
    sendRequest c w NET_WM_MOVERESIZE [x_root, y_root, direction, button, sourceIndication]
    where
    x_root           = fromMaybe 0 $ netWmMoveresize_x_root mr
    y_root           = fromMaybe 0 $ netWmMoveresize_y_root mr
    direction        = X.toValue $ netWmMoveresize_direction mr
    button           = X.toValue $ netWmMoveresize_button mr
    sourceIndication = X.toValue $ netWmMoveresize_sourceIndication mr

requestNetRestackWindow :: BasicEwmhCtx m => Connection -> WINDOW -> NetRestackWindow -> m ()
requestNetRestackWindow c w rw = do
    sendRequest c w NET_RESTACK_WINDOW ([sourceIndication, sibling_window, detail] :: [Word32])
    where
    sourceIndication = X.toValue $ netRestackWindow_sourceIndication rw
    sibling_window   = X.fromXid . X.toXid $ netRestackWindow_sibling_window rw
    detail           = X.toValue $ netRestackWindow_detail rw

requestNetRequestFrameExtents :: BasicEwmhCtx m => Connection -> WINDOW -> m ()
requestNetRequestFrameExtents c w = sendRequest c w NET_REQUEST_FRAME_EXTENTS ([] :: [Word32])

-----------------------------------
-- Application Window Properties --
-----------------------------------

getNetWmName :: BasicEwmhCtx m => Connection -> WINDOW -> m (Either SomeError [String])
getNetWmName c w = getProp c w NET_WM_NAME UTF8_STRING

setNetWmName :: BasicEwmhCtx m => Connection -> WINDOW -> [String] -> m ()
setNetWmName c w = setProp c w NET_WM_NAME UTF8_STRING

getNetWmVisibleName :: BasicEwmhCtx m => Connection -> WINDOW -> m (Either SomeError [String])
getNetWmVisibleName c w = getProp c w NET_WM_VISIBLE_NAME UTF8_STRING

setNetWmVisibleName :: BasicEwmhCtx m => Connection -> WINDOW -> [String] -> m ()
setNetWmVisibleName c w = setProp c w NET_WM_VISIBLE_NAME UTF8_STRING

getNetWmIconName :: BasicEwmhCtx m => Connection -> WINDOW -> m (Either SomeError [String])
getNetWmIconName c w = getProp c w NET_WM_ICON_NAME UTF8_STRING

setNetWmIconName :: BasicEwmhCtx m => Connection -> WINDOW -> [String] -> m ()
setNetWmIconName c w = setProp c w NET_WM_ICON_NAME UTF8_STRING

getNetWmVisibleIconName :: BasicEwmhCtx m => Connection -> WINDOW -> m (Either SomeError [String])
getNetWmVisibleIconName c w = getProp c w NET_WM_VISIBLE_ICON_NAME UTF8_STRING

setNetWmVisibleIconName :: BasicEwmhCtx m => Connection -> WINDOW -> [String] -> m ()
setNetWmVisibleIconName c w = setProp c w NET_WM_VISIBLE_ICON_NAME UTF8_STRING

getNetWmDesktop :: BasicEwmhCtx m => Connection -> WINDOW -> m (Either SomeError Word32)
getNetWmDesktop c w = getProp c w NET_WM_DESKTOP AtomCARDINAL

setNetWmDesktop :: BasicEwmhCtx m => Connection -> WINDOW -> Word32 -> m ()
setNetWmDesktop c w = setProp c w NET_WM_DESKTOP AtomCARDINAL

requestNetWmDesktop ::BasicEwmhCtx m => Connection -> WINDOW -> NetWmDesktop -> m ()
requestNetWmDesktop c w d = sendRequest c w NET_WM_DESKTOP [desktop, source]
    where
    desktop = netWmDesktop_new_desktop d
    source  = X.toValue $ netWmDesktop_source_indication d

getNetWmWindowType :: BasicEwmhCtx m => Connection -> WINDOW -> m (Either SomeError [NET_WM_WINDOW_TYPE])
getNetWmWindowType c w = runExceptT $ do
    getProp c w NET_WM_WINDOW_TYPE AtomATOM
        >>= eitherToExcept
        >>= fmap (catMaybes . map fromAtom . catMaybes) . mapM lookupAtomId

setNetWmWindowType :: BasicEwmhCtx m => Connection -> WINDOW -> [NET_WM_WINDOW_TYPE] -> m ()
setNetWmWindowType c w vs = do
    mapM unsafeLookupATOM vs >>= setProp c w NET_WM_WINDOW_TYPE AtomATOM

getNetWmState :: BasicEwmhCtx m => Connection -> WINDOW -> m (Either SomeError [NET_WM_STATE])
getNetWmState c w = runExceptT $ do
    getProp c w NET_WM_STATE AtomATOM
        >>= eitherToExcept
        >>= fmap (catMaybes . map fromAtom . catMaybes) . mapM lookupAtomId

setNetWmState :: BasicEwmhCtx m => Connection -> WINDOW -> [NET_WM_STATE] -> m ()
setNetWmState c w vs = mapM unsafeLookupATOM vs >>= setProp c w NET_WM_STATE AtomATOM

-- requestNetWmState :: BasicEwmhCtx m => Connection -> WINDOW -> [NetWmStateRequest] -> m ()
-- requestNetWmState = do
