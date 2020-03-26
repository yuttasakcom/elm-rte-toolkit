module RichText.Commands exposing
    ( backspaceBlockNode
    , backspaceCommands
    , backspaceInlineElement
    , backspaceText
    , backspaceWord
    , defaultCommandBindings
    , defaultInputEventCommand
    , defaultKeyCommand
    , deleteBlockNode
    , deleteCommands
    , deleteInlineElement
    , deleteText
    , deleteWord
    , insertBlockNode
    , insertBlockNodeBeforeSelection
    , insertInlineElement
    , insertLineBreak
    , insertTextAtSelection
    , isEmptyTextBlock
    , joinBackward
    , joinForward
    , lift
    , liftConcatMapFunc
    , liftEmpty
    , removeRangeSelection
    , removeRangeSelectionAndInsert
    , removeSelectedLeafElement
    , selectAll
    , selectionIsBeginningOfTextBlock
    , selectionIsEndOfTextBlock
    , splitBlock
    , splitBlockHeaderToNewParagraph
    , splitTextBlock
    , toggleBlock
    , toggleMarkOnInlineNodes
    , toggleMarkSingleInlineNode
    , wrap
    )

import Array exposing (Array)
import Array.Extra
import List.Extra
import Regex
import RichText.Annotation as Annotation
    exposing
        ( annotateSelection
        , clear
        , clearSelectionAnnotations
        , selectionFromAnnotations
        )
import RichText.Config.Command
    exposing
        ( CommandBinding
        , CommandMap
        , InternalAction(..)
        , NamedCommandList
        , Transform
        , emptyCommandMap
        , inputEvent
        , internal
        , key
        , set
        , transform
        , withDefaultInputEventCommand
        , withDefaultKeyCommand
        )
import RichText.Config.Keys exposing (alt, backspace, delete, enter, return, shift, short)
import RichText.Internal.DeleteWord as DeleteWord
import RichText.Internal.Event exposing (InputEvent, KeyboardEvent)
import RichText.Model.Element as Element exposing (Element)
import RichText.Model.InlineElement as InlineElement
import RichText.Model.Mark as Mark exposing (Mark, MarkOrder, ToggleAction(..), hasMarkWithName, toggle)
import RichText.Model.Node as Node
    exposing
        ( Block
        , BlockChildren
        , Children(..)
        , Inline(..)
        , Path
        , block
        , blockChildren
        , childNodes
        , commonAncestor
        , decrement
        , increment
        , inlineChildren
        , marks
        , parent
        , toBlockArray
        , toInlineArray
        , toString
        , withChildNodes
        , withElement
        )
import RichText.Model.Selection
    exposing
        ( Selection
        , anchorNode
        , anchorOffset
        , caret
        , focusNode
        , focusOffset
        , isCollapsed
        , normalize
        , range
        , singleNodeRange
        )
import RichText.Model.State as State exposing (State, withRoot, withSelection)
import RichText.Model.Text as Text
import RichText.Node
    exposing
        ( Fragment(..)
        , Node(..)
        , allRange
        , concatMap
        , findBackwardFromExclusive
        , findClosestBlockPath
        , findForwardFrom
        , findForwardFromExclusive
        , findTextBlockNodeAncestor
        , indexedFoldl
        , indexedMap
        , isSelectable
        , joinBlocks
        , next
        , nodeAt
        , previous
        , removeInRange
        , removeNodeAndEmptyParents
        , replace
        , replaceWithFragment
        , splitBlockAtPathAndOffset
        , splitTextLeaf
        , toggleMark
        )
import RichText.Specs exposing (hardBreak)
import Set exposing (Set)
import String.Extra


backspaceCommands =
    [ ( "removeRangeSelection", transform removeRangeSelection )
    , ( "removeSelectedLeafElementCommand", transform removeSelectedLeafElement )
    , ( "backspaceInlineElement", transform backspaceInlineElement )
    , ( "backspaceBlockNode", transform backspaceBlockNode )
    , ( "joinBackward", transform joinBackward )
    ]


deleteCommands =
    [ ( "removeRangeSelection", transform removeRangeSelection )
    , ( "removeSelectedLeafElementCommand", transform removeSelectedLeafElement )
    , ( "deleteInlineElement", transform deleteInlineElement )
    , ( "deleteBlockNode", transform deleteBlockNode )
    , ( "joinForward", transform joinForward )
    ]


defaultCommandBindings =
    emptyCommandMap
        |> set
            [ inputEvent "insertLineBreak", key [ shift, enter ], key [ shift, return ] ]
            [ ( "insertLineBreak", transform insertLineBreak ) ]
        |> set [ inputEvent "insertParagraph", key [ enter ], key [ return ] ]
            [ ( "liftEmpty", transform liftEmpty ), ( "splitTextBlock", transform splitTextBlock ) ]
        |> set [ inputEvent "deleteContentBackward", key [ backspace ] ]
            (backspaceCommands ++ [ ( "backspaceText", transform backspaceText ) ])
        |> set [ inputEvent "deleteWordBackward", key [ alt, backspace ] ]
            (backspaceCommands ++ [ ( "backspaceWord", transform backspaceWord ) ])
        |> set [ inputEvent "deleteContentForward", key [ delete ] ]
            (deleteCommands ++ [ ( "deleteText", transform deleteText ) ])
        |> set [ inputEvent "deleteWordForward", key [ alt, delete ] ]
            (deleteCommands ++ [ ( "deleteWord", transform deleteWord ) ])
        |> set [ key [ short, "a" ] ]
            [ ( "selectAll", transform selectAll ) ]
        |> set [ key [ short, "z" ] ]
            [ ( "undo", internal Undo ) ]
        |> set [ key [ short, shift, "z" ] ]
            [ ( "redo", internal Redo ) ]
        |> withDefaultKeyCommand defaultKeyCommand
        |> withDefaultInputEventCommand defaultInputEventCommand


defaultKeyCommand : KeyboardEvent -> NamedCommandList
defaultKeyCommand event =
    if not event.altKey && not event.metaKey && not event.ctrlKey && String.length event.key == 1 then
        [ ( "removeRangeAndInsert", transform <| removeRangeSelectionAndInsert event.key ) ]

    else
        []


defaultInputEventCommand : InputEvent -> NamedCommandList
defaultInputEventCommand event =
    if event.inputType == "insertText" then
        case event.data of
            Nothing ->
                []

            Just data ->
                [ ( "removeRangeAndInsert", transform <| removeRangeSelectionAndInsert data ) ]

    else
        []


removeRangeSelectionAndInsert : String -> Transform
removeRangeSelectionAndInsert s editorState =
    Result.map
        (\removedRangeEditorState ->
            Result.withDefault
                removedRangeEditorState
                (insertTextAtSelection s removedRangeEditorState)
        )
        (removeRangeSelection editorState)


insertTextAtSelection : String -> Transform
insertTextAtSelection s editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                Err "I can only insert text if the range is collapsed"

            else
                case nodeAt (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "Invalid selection after remove range"

                    Just node ->
                        case node of
                            Block _ ->
                                Err "I was expected a text leaf, but instead I found a block node"

                            Inline il ->
                                case il of
                                    InlineElement _ ->
                                        Err "I was expecting a text leaf, but instead found a block node"

                                    Text tl ->
                                        let
                                            newText =
                                                String.Extra.insertAt s (anchorOffset selection) (Text.text tl)

                                            newTextLeaf =
                                                Text (tl |> Text.withText newText)
                                        in
                                        case
                                            replace
                                                (anchorNode selection)
                                                (Inline newTextLeaf)
                                                (State.root editorState)
                                        of
                                            Err e ->
                                                Err e

                                            Ok newRoot ->
                                                Ok
                                                    (editorState
                                                        |> withRoot newRoot
                                                        |> withSelection
                                                            (Just <|
                                                                caret
                                                                    (anchorNode selection)
                                                                    (anchorOffset selection + 1)
                                                            )
                                                    )


joinBackward : Transform
joinBackward editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| selectionIsBeginningOfTextBlock selection (State.root editorState) then
                Err "I cannot join a selection that is not the beginning of a text block"

            else
                case findTextBlockNodeAncestor (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "There is no text block at the selection"

                    Just ( textBlockPath, _ ) ->
                        case findPreviousTextBlock textBlockPath (State.root editorState) of
                            Nothing ->
                                Err "There is no text block I can join backward with"

                            Just ( p, n ) ->
                                -- We're going to transpose this into joinForward by setting the selection to the end of the
                                -- given text block
                                case childNodes n of
                                    InlineChildren a ->
                                        let
                                            array =
                                                toInlineArray a
                                        in
                                        case Array.get (Array.length array - 1) array of
                                            Nothing ->
                                                Err "There must be at least one element in the inline node to join with"

                                            Just leaf ->
                                                let
                                                    newSelection =
                                                        case leaf of
                                                            Text tl ->
                                                                caret
                                                                    (p ++ [ Array.length array - 1 ])
                                                                    (String.length (Text.text tl))

                                                            InlineElement _ ->
                                                                caret
                                                                    (p ++ [ Array.length array - 1 ])
                                                                    0
                                                in
                                                joinForward
                                                    (editorState
                                                        |> withSelection (Just newSelection)
                                                    )

                                    _ ->
                                        Err "I can only join with text blocks"


selectionIsBeginningOfTextBlock : Selection -> Block -> Bool
selectionIsBeginningOfTextBlock selection root =
    if not <| isCollapsed selection then
        False

    else
        case findTextBlockNodeAncestor (anchorNode selection) root of
            Nothing ->
                False

            Just ( _, n ) ->
                case childNodes n of
                    InlineChildren a ->
                        case List.Extra.last (anchorNode selection) of
                            Nothing ->
                                False

                            Just i ->
                                if i /= 0 || Array.isEmpty (toInlineArray a) then
                                    False

                                else
                                    anchorOffset selection == 0

                    _ ->
                        False


selectionIsEndOfTextBlock : Selection -> Block -> Bool
selectionIsEndOfTextBlock selection root =
    if not <| isCollapsed selection then
        False

    else
        case findTextBlockNodeAncestor (anchorNode selection) root of
            Nothing ->
                False

            Just ( _, n ) ->
                case childNodes n of
                    InlineChildren a ->
                        case List.Extra.last (anchorNode selection) of
                            Nothing ->
                                False

                            Just i ->
                                if i /= Array.length (toInlineArray a) - 1 then
                                    False

                                else
                                    case Array.get i (toInlineArray a) of
                                        Nothing ->
                                            False

                                        Just leaf ->
                                            case leaf of
                                                Text tl ->
                                                    String.length (Text.text tl) == anchorOffset selection

                                                InlineElement _ ->
                                                    True

                    _ ->
                        False


joinForward : Transform
joinForward editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| selectionIsEndOfTextBlock selection (State.root editorState) then
                Err "I cannot join a selection that is not at the end of a text block"

            else
                case findTextBlockNodeAncestor (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "The selection has no text block ancestor"

                    Just ( p1, n1 ) ->
                        case findNextTextBlock (anchorNode selection) (State.root editorState) of
                            Nothing ->
                                Err "There is no text block I can join forward with"

                            Just ( p2, n2 ) ->
                                case joinBlocks n1 n2 of
                                    Nothing ->
                                        Err <|
                                            "I could not join these two blocks at"
                                                ++ Node.toString p1
                                                ++ " ,"
                                                ++ Node.toString p2

                                    Just newBlock ->
                                        let
                                            removed =
                                                removeNodeAndEmptyParents p2 (State.root editorState)
                                        in
                                        case replace p1 (Block newBlock) removed of
                                            Err e ->
                                                Err e

                                            Ok b ->
                                                Ok
                                                    (editorState
                                                        |> withRoot b
                                                    )


isTextBlock : Path -> Node -> Bool
isTextBlock _ node =
    case node of
        Block bn ->
            case childNodes bn of
                InlineChildren _ ->
                    True

                _ ->
                    False

        _ ->
            False


type alias FindFunc =
    (Path -> Node -> Bool) -> Path -> Block -> Maybe ( Path, Node )


findTextBlock : FindFunc -> Path -> Block -> Maybe ( Path, Block )
findTextBlock findFunc path node =
    case
        findFunc
            isTextBlock
            path
            node
    of
        Nothing ->
            Nothing

        Just ( p, n ) ->
            case n of
                Block bn ->
                    Just ( p, bn )

                _ ->
                    Nothing


findNextTextBlock : Path -> Block -> Maybe ( Path, Block )
findNextTextBlock =
    findTextBlock findForwardFromExclusive


findPreviousTextBlock : Path -> Block -> Maybe ( Path, Block )
findPreviousTextBlock =
    findTextBlock findBackwardFromExclusive


removeRangeSelection : Transform
removeRangeSelection editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if isCollapsed selection then
                Err "Cannot remove contents of collapsed selection"

            else
                let
                    normalizedSelection =
                        normalize selection
                in
                if anchorNode normalizedSelection == focusNode normalizedSelection then
                    case
                        removeTextAtRange
                            (anchorNode normalizedSelection)
                            (anchorOffset normalizedSelection)
                            (Just (focusOffset normalizedSelection))
                            (State.root editorState)
                    of
                        Ok newRoot ->
                            let
                                newSelection =
                                    caret (anchorNode normalizedSelection) (anchorOffset normalizedSelection)
                            in
                            Ok
                                (editorState
                                    |> withRoot newRoot
                                    |> withSelection (Just newSelection)
                                )

                        Err s ->
                            Err s

                else
                    let
                        anchorTextBlock =
                            findTextBlockNodeAncestor
                                (anchorNode normalizedSelection)
                                (State.root editorState)

                        focusTextBlock =
                            findTextBlockNodeAncestor
                                (focusNode normalizedSelection)
                                (State.root editorState)
                    in
                    case
                        removeTextAtRange (focusNode normalizedSelection)
                            0
                            (Just (focusOffset normalizedSelection))
                            (State.root editorState)
                    of
                        Err s ->
                            Err s

                        Ok removedEnd ->
                            case
                                removeTextAtRange
                                    (anchorNode normalizedSelection)
                                    (anchorOffset normalizedSelection)
                                    Nothing
                                    removedEnd
                            of
                                Err s ->
                                    Err s

                                Ok removedStart ->
                                    let
                                        removedNodes =
                                            removeInRange
                                                (increment (anchorNode normalizedSelection))
                                                (decrement (focusNode normalizedSelection))
                                                removedStart

                                        newSelection =
                                            caret
                                                (anchorNode normalizedSelection)
                                                (anchorOffset normalizedSelection)

                                        newEditorState =
                                            editorState
                                                |> withRoot removedNodes
                                                |> withSelection (Just newSelection)
                                    in
                                    case anchorTextBlock of
                                        Nothing ->
                                            Ok newEditorState

                                        Just ( ap, _ ) ->
                                            case focusTextBlock of
                                                Nothing ->
                                                    Ok newEditorState

                                                Just ( fp, _ ) ->
                                                    if ap == fp then
                                                        Ok newEditorState

                                                    else
                                                        Ok <| Result.withDefault newEditorState (joinForward newEditorState)


insertLineBreak : Transform
insertLineBreak =
    insertInlineElement
        (Node.inlineElement (Element.element hardBreak []) [])


insertInlineElement : Inline -> Transform
insertInlineElement leaf editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                removeRangeSelection editorState |> Result.andThen (insertInlineElement leaf)

            else
                case nodeAt (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "Invalid selection"

                    Just node ->
                        case node of
                            Inline il ->
                                case il of
                                    InlineElement _ ->
                                        case
                                            replace
                                                (anchorNode selection)
                                                (Inline leaf)
                                                (State.root editorState)
                                        of
                                            Err e ->
                                                Err e

                                            Ok newRoot ->
                                                let
                                                    newSelection =
                                                        case
                                                            findForwardFrom
                                                                (\_ n -> isSelectable n)
                                                                (anchorNode selection)
                                                                newRoot
                                                        of
                                                            Nothing ->
                                                                Nothing

                                                            Just ( p, _ ) ->
                                                                Just (caret p 0)
                                                in
                                                Ok
                                                    (editorState
                                                        |> withRoot newRoot
                                                        |> withSelection newSelection
                                                    )

                                    Text tl ->
                                        let
                                            ( before, after ) =
                                                splitTextLeaf (anchorOffset selection) tl
                                        in
                                        case
                                            replaceWithFragment
                                                (anchorNode selection)
                                                (InlineLeafFragment
                                                    (Array.fromList
                                                        [ Text before, leaf, Text after ]
                                                    )
                                                )
                                                (State.root editorState)
                                        of
                                            Err e ->
                                                Err e

                                            Ok newRoot ->
                                                let
                                                    newSelection =
                                                        case
                                                            findForwardFromExclusive
                                                                (\_ n -> isSelectable n)
                                                                (anchorNode selection)
                                                                newRoot
                                                        of
                                                            Nothing ->
                                                                Nothing

                                                            Just ( p, _ ) ->
                                                                Just (caret p 0)
                                                in
                                                Ok
                                                    (editorState
                                                        |> withRoot newRoot
                                                        |> withSelection newSelection
                                                    )

                            _ ->
                                Err "I can not insert an inline element in a block node"


splitTextBlock : Transform
splitTextBlock =
    splitBlock findTextBlockNodeAncestor


splitBlock : (Path -> Block -> Maybe ( Path, Block )) -> Transform
splitBlock ancestorFunc editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                removeRangeSelection editorState |> Result.andThen (splitBlock ancestorFunc)

            else
                case ancestorFunc (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "I cannot find a proper ancestor to split"

                    Just ( textBlockPath, textBlockNode ) ->
                        let
                            relativePath =
                                List.drop (List.length textBlockPath) (anchorNode selection)
                        in
                        case splitBlockAtPathAndOffset relativePath (anchorOffset selection) textBlockNode of
                            Nothing ->
                                Err <| "Can not split block at path " ++ toString (anchorNode selection)

                            Just ( before, after ) ->
                                case
                                    replaceWithFragment
                                        textBlockPath
                                        (BlockNodeFragment (Array.fromList [ before, after ]))
                                        (State.root editorState)
                                of
                                    Err s ->
                                        Err s

                                    Ok newRoot ->
                                        let
                                            newSelectionPath =
                                                increment textBlockPath ++ [ 0 ]

                                            newSelection =
                                                caret newSelectionPath 0
                                        in
                                        Ok
                                            (editorState
                                                |> withRoot newRoot
                                                |> withSelection (Just newSelection)
                                            )


isLeafNode : Path -> Block -> Bool
isLeafNode path root =
    case nodeAt path root of
        Nothing ->
            False

        Just node ->
            case node of
                Block bn ->
                    case childNodes bn of
                        Leaf ->
                            True

                        _ ->
                            False

                Inline l ->
                    case l of
                        InlineElement _ ->
                            True

                        Text _ ->
                            False


removeTextAtRange : Path -> Int -> Maybe Int -> Block -> Result String Block
removeTextAtRange nodePath start maybeEnd root =
    case nodeAt nodePath root of
        Just node ->
            case node of
                Block _ ->
                    Err "I was expecting a text node, but instead I got a block node"

                Inline leaf ->
                    case leaf of
                        InlineElement _ ->
                            Err "I was expecting a text leaf, but instead I got an inline leaf"

                        Text v ->
                            let
                                textNode =
                                    case maybeEnd of
                                        Nothing ->
                                            Text
                                                (v
                                                    |> Text.withText (String.left start (Text.text v))
                                                )

                                        Just end ->
                                            Text
                                                (v
                                                    |> Text.withText
                                                        (String.left start (Text.text v)
                                                            ++ String.dropLeft end (Text.text v)
                                                        )
                                                )
                            in
                            replace nodePath (Inline textNode) root

        Nothing ->
            Err <| "There is no node at node path " ++ toString nodePath


removeSelectedLeafElement : Transform
removeSelectedLeafElement editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                Err "I cannot remove a block element if it is not"

            else if isLeafNode (anchorNode selection) (State.root editorState) then
                let
                    newSelection =
                        case
                            findBackwardFromExclusive
                                (\_ n -> isSelectable n)
                                (anchorNode selection)
                                (State.root editorState)
                        of
                            Nothing ->
                                Nothing

                            Just ( p, n ) ->
                                let
                                    offset =
                                        case n of
                                            Inline il ->
                                                case il of
                                                    Text t ->
                                                        String.length (Text.text t)

                                                    _ ->
                                                        0

                                            _ ->
                                                0
                                in
                                Just (caret p offset)
                in
                Ok
                    (editorState
                        |> withRoot (removeNodeAndEmptyParents (anchorNode selection) (State.root editorState))
                        |> withSelection newSelection
                    )

            else
                Err "There's no leaf node at the given selection"



-- backspace logic for text
-- offset = 0, try to delete the previous text node's text
-- offset = 1, set the text node to empty
-- other offset, allow browser to do the default behavior


backspaceText : Transform
backspaceText editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                Err "I can only backspace a collapsed selection"

            else if anchorOffset selection > 1 then
                Err <|
                    "I use native behavior when doing backspace when the "
                        ++ "anchor offset could not result in a node change"

            else
                case nodeAt (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "Invalid selection"

                    Just node ->
                        case node of
                            Block _ ->
                                Err "I cannot backspace a block node"

                            Inline il ->
                                case il of
                                    InlineElement _ ->
                                        Err "I cannot backspace text of an inline leaf"

                                    Text tl ->
                                        if anchorOffset selection == 1 then
                                            case
                                                replace (anchorNode selection)
                                                    (Inline
                                                        (Text
                                                            (tl
                                                                |> Text.withText (String.dropLeft 1 (Text.text tl))
                                                            )
                                                        )
                                                    )
                                                    (State.root editorState)
                                            of
                                                Err s ->
                                                    Err s

                                                Ok newRoot ->
                                                    let
                                                        newSelection =
                                                            caret (anchorNode selection) 0
                                                    in
                                                    Ok
                                                        (editorState
                                                            |> withRoot newRoot
                                                            |> withSelection (Just newSelection)
                                                        )

                                        else
                                            case previous (anchorNode selection) (State.root editorState) of
                                                Nothing ->
                                                    Err "No previous node to backspace text"

                                                Just ( previousPath, previousNode ) ->
                                                    case previousNode of
                                                        Inline previousInlineLeafWrapper ->
                                                            case previousInlineLeafWrapper of
                                                                Text previousTextLeaf ->
                                                                    let
                                                                        l =
                                                                            String.length (Text.text previousTextLeaf)

                                                                        newSelection =
                                                                            singleNodeRange previousPath l (max 0 (l - 1))
                                                                    in
                                                                    removeRangeSelection
                                                                        (editorState
                                                                            |> withSelection (Just newSelection)
                                                                        )

                                                                InlineElement _ ->
                                                                    Err "Cannot backspace the text of an inline leaf"

                                                        Block _ ->
                                                            Err "Cannot backspace the text of a block node"


isBlockOrInlineNodeWithMark : String -> Node -> Bool
isBlockOrInlineNodeWithMark markName node =
    case node of
        Inline il ->
            hasMarkWithName markName (marks il)

        _ ->
            True


toggleMarkSingleInlineNode : MarkOrder -> Mark -> ToggleAction -> Transform
toggleMarkSingleInlineNode markOrder mark action editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if anchorNode selection /= focusNode selection then
                Err "I can only toggle a single inline node"

            else
                let
                    normalizedSelection =
                        normalize selection
                in
                case nodeAt (anchorNode normalizedSelection) (State.root editorState) of
                    Nothing ->
                        Err "No node at selection"

                    Just node ->
                        case node of
                            Block _ ->
                                Err "Cannot toggle a block node"

                            Inline il ->
                                let
                                    newMarks =
                                        toggle action markOrder mark (marks il)

                                    leaves =
                                        case il of
                                            InlineElement leaf ->
                                                [ InlineElement
                                                    (leaf
                                                        |> InlineElement.withMarks newMarks
                                                    )
                                                ]

                                            Text leaf ->
                                                if
                                                    String.length (Text.text leaf)
                                                        == focusOffset normalizedSelection
                                                        && anchorOffset normalizedSelection
                                                        == 0
                                                then
                                                    [ Text (leaf |> Text.withMarks newMarks) ]

                                                else
                                                    let
                                                        newNode =
                                                            Text
                                                                (leaf
                                                                    |> Text.withMarks newMarks
                                                                    |> Text.withText
                                                                        (String.slice
                                                                            (anchorOffset normalizedSelection)
                                                                            (focusOffset normalizedSelection)
                                                                            (Text.text leaf)
                                                                        )
                                                                )

                                                        left =
                                                            Text
                                                                (leaf
                                                                    |> Text.withText
                                                                        (String.left
                                                                            (anchorOffset normalizedSelection)
                                                                            (Text.text leaf)
                                                                        )
                                                                )

                                                        right =
                                                            Text
                                                                (leaf
                                                                    |> Text.withText
                                                                        (String.dropLeft
                                                                            (focusOffset normalizedSelection)
                                                                            (Text.text leaf)
                                                                        )
                                                                )
                                                    in
                                                    if anchorOffset normalizedSelection == 0 then
                                                        [ newNode, right ]

                                                    else if String.length (Text.text leaf) == focusOffset normalizedSelection then
                                                        [ left, newNode ]

                                                    else
                                                        [ left, newNode, right ]

                                    path =
                                        if anchorOffset normalizedSelection == 0 then
                                            anchorNode normalizedSelection

                                        else
                                            increment (anchorNode normalizedSelection)

                                    newSelection =
                                        singleNodeRange
                                            path
                                            0
                                            (focusOffset normalizedSelection - anchorOffset normalizedSelection)
                                in
                                case
                                    replaceWithFragment
                                        (anchorNode normalizedSelection)
                                        (InlineLeafFragment <| Array.fromList leaves)
                                        (State.root editorState)
                                of
                                    Err s ->
                                        Err s

                                    Ok newRoot ->
                                        Ok
                                            (editorState
                                                |> withSelection (Just newSelection)
                                                |> withRoot newRoot
                                            )


toggleMarkOnInlineNodes : MarkOrder -> Mark -> ToggleAction -> Transform
toggleMarkOnInlineNodes markOrder mark action editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if focusNode selection == anchorNode selection then
                toggleMarkSingleInlineNode markOrder mark Flip editorState

            else
                let
                    normalizedSelection =
                        normalize selection

                    toggleAction =
                        if action /= Flip then
                            action

                        else if
                            allRange
                                (isBlockOrInlineNodeWithMark (Mark.name mark))
                                (anchorNode normalizedSelection)
                                (focusNode normalizedSelection)
                                (State.root editorState)
                        then
                            Remove

                        else
                            Add

                    betweenRoot =
                        case next (anchorNode normalizedSelection) (State.root editorState) of
                            Nothing ->
                                State.root editorState

                            Just ( afterAnchor, _ ) ->
                                case previous (focusNode normalizedSelection) (State.root editorState) of
                                    Nothing ->
                                        State.root editorState

                                    Just ( beforeFocus, _ ) ->
                                        case
                                            indexedMap
                                                (\path node ->
                                                    if path < afterAnchor || path > beforeFocus then
                                                        node

                                                    else
                                                        case node of
                                                            Block _ ->
                                                                node

                                                            Inline _ ->
                                                                toggleMark toggleAction markOrder mark node
                                                )
                                                (Block (State.root editorState))
                                        of
                                            Block bn ->
                                                bn

                                            _ ->
                                                State.root editorState

                    modifiedEndNodeEditorState =
                        Result.withDefault (editorState |> withRoot betweenRoot) <|
                            toggleMarkSingleInlineNode
                                markOrder
                                mark
                                toggleAction
                                (editorState
                                    |> withRoot betweenRoot
                                    |> withSelection
                                        (Just
                                            (singleNodeRange
                                                (focusNode normalizedSelection)
                                                0
                                                (focusOffset normalizedSelection)
                                            )
                                        )
                                )

                    modifiedStartNodeEditorState =
                        case nodeAt (anchorNode normalizedSelection) (State.root editorState) of
                            Nothing ->
                                modifiedEndNodeEditorState

                            Just node ->
                                case node of
                                    Inline il ->
                                        let
                                            focusOffset =
                                                case il of
                                                    Text leaf ->
                                                        String.length (Text.text leaf)

                                                    InlineElement _ ->
                                                        0
                                        in
                                        Result.withDefault modifiedEndNodeEditorState <|
                                            toggleMarkSingleInlineNode
                                                markOrder
                                                mark
                                                toggleAction
                                                (modifiedEndNodeEditorState
                                                    |> withSelection
                                                        (Just
                                                            (singleNodeRange
                                                                (anchorNode normalizedSelection)
                                                                (anchorOffset normalizedSelection)
                                                                focusOffset
                                                            )
                                                        )
                                                )

                                    _ ->
                                        modifiedEndNodeEditorState

                    incrementAnchorOffset =
                        anchorOffset normalizedSelection /= 0

                    anchorAndFocusHaveSameParent =
                        parent (anchorNode normalizedSelection) == parent (focusNode normalizedSelection)

                    newSelection =
                        range
                            (if incrementAnchorOffset then
                                increment (anchorNode normalizedSelection)

                             else
                                anchorNode normalizedSelection
                            )
                            0
                            (if incrementAnchorOffset && anchorAndFocusHaveSameParent then
                                increment (focusNode normalizedSelection)

                             else
                                focusNode normalizedSelection
                            )
                            (focusOffset normalizedSelection)
                in
                Ok
                    (modifiedStartNodeEditorState
                        |> withSelection (Just newSelection)
                    )


toggleBlock : List String -> Element -> Element -> Transform
toggleBlock allowedBlocks onParams offParams editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected."

        Just selection ->
            let
                normalizedSelection =
                    normalize selection

                anchorPath =
                    findClosestBlockPath (anchorNode normalizedSelection) (State.root editorState)

                focusPath =
                    findClosestBlockPath (focusNode normalizedSelection) (State.root editorState)

                doOffBehavior =
                    allRange
                        (\node ->
                            case node of
                                Block bn ->
                                    Node.element bn == onParams

                                _ ->
                                    True
                        )
                        anchorPath
                        focusPath
                        (State.root editorState)

                newParams =
                    if doOffBehavior then
                        offParams

                    else
                        onParams

                newRoot =
                    case
                        indexedMap
                            (\path node ->
                                if path < anchorPath || path > focusPath then
                                    node

                                else
                                    case node of
                                        Block bn ->
                                            let
                                                p =
                                                    Node.element bn
                                            in
                                            if List.member (Element.name p) allowedBlocks then
                                                Block (bn |> withElement newParams)

                                            else
                                                node

                                        Inline _ ->
                                            node
                            )
                            (Block (State.root editorState))
                    of
                        Block bn ->
                            bn

                        _ ->
                            State.root editorState
            in
            Ok (editorState |> withRoot newRoot)


wrap : (Block -> Block) -> Element -> Transform
wrap contentsMapFunc elementParameters editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            let
                normalizedSelection =
                    normalize selection

                markedRoot =
                    annotateSelection normalizedSelection (State.root editorState)

                anchorBlockPath =
                    findClosestBlockPath (anchorNode normalizedSelection) markedRoot

                focusBlockPath =
                    findClosestBlockPath (focusNode normalizedSelection) markedRoot

                ancestor =
                    commonAncestor anchorBlockPath focusBlockPath
            in
            if ancestor == anchorBlockPath || ancestor == focusBlockPath then
                case nodeAt ancestor markedRoot of
                    Nothing ->
                        Err "I cannot find a node at selection"

                    Just node ->
                        let
                            newChildren =
                                case node of
                                    Block bn ->
                                        blockChildren (Array.map contentsMapFunc (Array.fromList [ bn ]))

                                    Inline il ->
                                        inlineChildren (Array.fromList [ il ])

                            newNode =
                                block elementParameters newChildren
                        in
                        case replace ancestor (Block newNode) markedRoot of
                            Err err ->
                                Err err

                            Ok newRoot ->
                                Ok
                                    (editorState
                                        |> withRoot (clearSelectionAnnotations newRoot)
                                        |> withSelection
                                            (selectionFromAnnotations
                                                newRoot
                                                (anchorOffset selection)
                                                (focusOffset selection)
                                            )
                                    )

            else
                case List.Extra.getAt (List.length ancestor) (anchorNode normalizedSelection) of
                    Nothing ->
                        Err "Invalid ancestor path at anchor node"

                    Just childAnchorIndex ->
                        case List.Extra.getAt (List.length ancestor) (focusNode normalizedSelection) of
                            Nothing ->
                                Err "Invalid ancestor path at focus node"

                            Just childFocusIndex ->
                                case nodeAt ancestor markedRoot of
                                    Nothing ->
                                        Err "Invalid common ancestor path"

                                    Just node ->
                                        case node of
                                            Block bn ->
                                                case childNodes bn of
                                                    BlockChildren a ->
                                                        let
                                                            newChildNode =
                                                                block elementParameters
                                                                    (blockChildren <|
                                                                        Array.map
                                                                            contentsMapFunc
                                                                            (Array.slice childAnchorIndex
                                                                                (childFocusIndex + 1)
                                                                                (toBlockArray a)
                                                                            )
                                                                    )

                                                            newBlockArray =
                                                                blockChildren <|
                                                                    Array.append
                                                                        (Array.append
                                                                            (Array.Extra.sliceUntil
                                                                                childAnchorIndex
                                                                                (toBlockArray a)
                                                                            )
                                                                            (Array.fromList [ newChildNode ])
                                                                        )
                                                                        (Array.Extra.sliceFrom
                                                                            (childFocusIndex + 1)
                                                                            (toBlockArray a)
                                                                        )

                                                            newNode =
                                                                bn |> withChildNodes newBlockArray
                                                        in
                                                        case replace ancestor (Block newNode) markedRoot of
                                                            Err s ->
                                                                Err s

                                                            Ok newRoot ->
                                                                Ok
                                                                    (editorState
                                                                        |> withRoot (clearSelectionAnnotations newRoot)
                                                                        |> withSelection
                                                                            (selectionFromAnnotations
                                                                                newRoot
                                                                                (anchorOffset selection)
                                                                                (focusOffset selection)
                                                                            )
                                                                    )

                                                    InlineChildren _ ->
                                                        Err "Cannot wrap inline elements"

                                                    Leaf ->
                                                        Err "Cannot wrap leaf elements"

                                            Inline _ ->
                                                Err "Invalid ancestor path... somehow we have an inline leaf"


selectAll : Transform
selectAll editorState =
    let
        ( fl, lastOffset ) =
            indexedFoldl
                (\path node ( firstAndLast, offset ) ->
                    if isSelectable node then
                        let
                            newOffset =
                                case node of
                                    Inline il ->
                                        case il of
                                            Text tl ->
                                                String.length (Text.text tl)

                                            InlineElement _ ->
                                                0

                                    Block _ ->
                                        0
                        in
                        case firstAndLast of
                            Nothing ->
                                ( Just ( path, path ), newOffset )

                            Just ( first, _ ) ->
                                ( Just ( first, path ), newOffset )

                    else
                        ( firstAndLast, offset )
                )
                ( Nothing, 0 )
                (Block (State.root editorState))
    in
    case fl of
        Nothing ->
            Err "Nothing is selectable"

        Just ( first, last ) ->
            Ok
                (editorState
                    |> withSelection (Just <| range first 0 last lastOffset)
                )


addLiftMarkToBlocksInSelection : Selection -> Block -> Block
addLiftMarkToBlocksInSelection selection root =
    let
        start =
            findClosestBlockPath (anchorNode selection) root

        end =
            findClosestBlockPath (focusNode selection) root
    in
    case
        indexedMap
            (\path node ->
                if path < start || path > end then
                    node

                else
                    case node of
                        Block bn ->
                            let
                                addMarker =
                                    case childNodes bn of
                                        Leaf ->
                                            True

                                        InlineChildren _ ->
                                            True

                                        _ ->
                                            False
                            in
                            if addMarker then
                                Annotation.add Annotation.lift <| Block bn

                            else
                                node

                        _ ->
                            node
            )
            (Block root)
    of
        Block bn ->
            bn

        _ ->
            root


annotationsFromBlockNode : Block -> Set String
annotationsFromBlockNode node =
    Element.annotations <| Node.element node


liftConcatMapFunc : Node -> List Node
liftConcatMapFunc node =
    case node of
        Block bn ->
            case childNodes bn of
                Leaf ->
                    [ node ]

                InlineChildren _ ->
                    [ node ]

                BlockChildren a ->
                    let
                        groupedBlockNodes =
                            List.Extra.groupWhile
                                (\n1 n2 ->
                                    Set.member
                                        Annotation.lift
                                        (annotationsFromBlockNode n1)
                                        == Set.member
                                            Annotation.lift
                                            (annotationsFromBlockNode n2)
                                )
                                (Array.toList (toBlockArray a))
                    in
                    List.map Block <|
                        List.concatMap
                            (\( n, l ) ->
                                if Set.member Annotation.lift (annotationsFromBlockNode n) then
                                    n :: l

                                else
                                    [ bn |> withChildNodes (blockChildren (Array.fromList <| n :: l)) ]
                            )
                            groupedBlockNodes

        Inline _ ->
            [ node ]


lift : Transform
lift editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            let
                normalizedSelection =
                    normalize selection

                markedRoot =
                    addLiftMarkToBlocksInSelection normalizedSelection <|
                        annotateSelection normalizedSelection (State.root editorState)

                liftedRoot =
                    concatMap liftConcatMapFunc markedRoot

                newSelection =
                    selectionFromAnnotations
                        liftedRoot
                        (anchorOffset normalizedSelection)
                        (focusOffset normalizedSelection)
            in
            Ok
                (editorState
                    |> withSelection newSelection
                    |> withRoot
                        (clear Annotation.lift <|
                            clearSelectionAnnotations liftedRoot
                        )
                )


liftEmpty : Transform
liftEmpty editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if (not <| isCollapsed selection) || anchorOffset selection /= 0 then
                Err "Can only lift empty text blocks"

            else
                let
                    p =
                        findClosestBlockPath (anchorNode selection) (State.root editorState)
                in
                case nodeAt p (State.root editorState) of
                    Nothing ->
                        Err "Invalid root path"

                    Just node ->
                        if not <| isEmptyTextBlock node then
                            Err "I cannot lift a node that is not an empty text block"

                        else if List.length p < 2 then
                            Err "I cannot lift a node that's root or an immediate child of root"

                        else
                            lift editorState


isEmptyTextBlock : Node -> Bool
isEmptyTextBlock node =
    case node of
        Block bn ->
            case childNodes bn of
                InlineChildren a ->
                    let
                        array =
                            toInlineArray a
                    in
                    case Array.get 0 array of
                        Nothing ->
                            Array.isEmpty array

                        Just n ->
                            Array.length array
                                == 1
                                && (case n of
                                        Text t ->
                                            String.isEmpty (Text.text t)

                                        _ ->
                                            False
                                   )

                _ ->
                    False

        Inline _ ->
            False


splitBlockHeaderToNewParagraph : List String -> Element -> Transform
splitBlockHeaderToNewParagraph headerElements paragraphElement editorState =
    case splitTextBlock editorState of
        Err s ->
            Err s

        Ok splitEditorState ->
            case State.selection splitEditorState of
                Nothing ->
                    Ok splitEditorState

                Just selection ->
                    if (not <| isCollapsed selection) || anchorOffset selection /= 0 then
                        Ok splitEditorState

                    else
                        let
                            p =
                                findClosestBlockPath
                                    (anchorNode selection)
                                    (State.root splitEditorState)
                        in
                        case nodeAt p (State.root splitEditorState) of
                            Nothing ->
                                Ok splitEditorState

                            Just node ->
                                case node of
                                    Block bn ->
                                        let
                                            parameters =
                                                Node.element bn
                                        in
                                        if
                                            List.member
                                                (Element.name parameters)
                                                headerElements
                                                && isEmptyTextBlock node
                                        then
                                            case
                                                replace p
                                                    (Block
                                                        (bn
                                                            |> withElement
                                                                paragraphElement
                                                        )
                                                    )
                                                    (State.root splitEditorState)
                                            of
                                                Err _ ->
                                                    Ok splitEditorState

                                                Ok newRoot ->
                                                    Ok (splitEditorState |> withRoot newRoot)

                                        else
                                            Ok splitEditorState

                                    _ ->
                                        Ok splitEditorState


insertBlockNode : Block -> Transform
insertBlockNode node editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                removeRangeSelection editorState |> Result.andThen (insertBlockNode node)

            else
                case nodeAt (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "Invalid selection"

                    Just aNode ->
                        case aNode of
                            -- if a block node is selected, then insert after the selected block
                            Block bn ->
                                case
                                    replaceWithFragment
                                        (anchorNode selection)
                                        (BlockNodeFragment (Array.fromList [ bn, node ]))
                                        (State.root editorState)
                                of
                                    Err s ->
                                        Err s

                                    Ok newRoot ->
                                        let
                                            newSelection =
                                                if isSelectable (Block node) then
                                                    caret (increment (anchorNode selection)) 0

                                                else
                                                    selection
                                        in
                                        Ok
                                            (editorState
                                                |> withSelection (Just newSelection)
                                                |> withRoot newRoot
                                            )

                            -- if an inline node is selected, then split the block and insert before
                            Inline _ ->
                                case splitTextBlock editorState of
                                    Err s ->
                                        Err s

                                    Ok splitEditorState ->
                                        insertBlockNodeBeforeSelection node splitEditorState


insertBlockNodeBeforeSelection : Block -> Transform
insertBlockNodeBeforeSelection node editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                Err "I can only insert a block element before a collapsed selection"

            else
                let
                    markedRoot =
                        annotateSelection selection (State.root editorState)

                    closestBlockPath =
                        findClosestBlockPath (anchorNode selection) markedRoot
                in
                case nodeAt closestBlockPath markedRoot of
                    Nothing ->
                        Err "Invalid selection"

                    Just anchorNode ->
                        case anchorNode of
                            Block bn ->
                                let
                                    newFragment =
                                        if isEmptyTextBlock <| Block bn then
                                            [ node ]

                                        else
                                            [ node, bn ]
                                in
                                case
                                    replaceWithFragment
                                        closestBlockPath
                                        (BlockNodeFragment (Array.fromList newFragment))
                                        markedRoot
                                of
                                    Err s ->
                                        Err s

                                    Ok newRoot ->
                                        let
                                            newSelection =
                                                if isSelectable (Block node) then
                                                    Just <| caret closestBlockPath 0

                                                else
                                                    selectionFromAnnotations
                                                        newRoot
                                                        (anchorOffset selection)
                                                        (focusOffset selection)
                                        in
                                        Ok
                                            (editorState
                                                |> withSelection newSelection
                                                |> withRoot (clearSelectionAnnotations newRoot)
                                            )

                            -- if an inline node is selected, then split the block and insert before
                            Inline _ ->
                                Err "Invalid state! I was expecting a block node."


backspaceInlineElement : Transform
backspaceInlineElement editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                Err "I can only backspace an inline element if the selection is collapsed"

            else if anchorOffset selection /= 0 then
                Err "I can only backspace an inline element if the offset is 0"

            else
                let
                    decrementedPath =
                        decrement (anchorNode selection)
                in
                case nodeAt decrementedPath (State.root editorState) of
                    Nothing ->
                        Err "There is no previous inline element"

                    Just node ->
                        case node of
                            Inline il ->
                                case il of
                                    InlineElement _ ->
                                        case
                                            replaceWithFragment
                                                decrementedPath
                                                (InlineLeafFragment Array.empty)
                                                (State.root editorState)
                                        of
                                            Err s ->
                                                Err s

                                            Ok newRoot ->
                                                Ok
                                                    (editorState
                                                        |> withSelection (Just <| caret decrementedPath 0)
                                                        |> withRoot newRoot
                                                    )

                                    Text _ ->
                                        Err "There is no previous inline leaf element, found a text leaf"

                            Block _ ->
                                Err "There is no previous inline leaf element, found a block node"


backspaceBlockNode : Transform
backspaceBlockNode editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| selectionIsBeginningOfTextBlock selection (State.root editorState) then
                Err "Cannot backspace a block element if we're not at the beginning of a text block"

            else
                let
                    blockPath =
                        findClosestBlockPath (anchorNode selection) (State.root editorState)

                    markedRoot =
                        annotateSelection selection (State.root editorState)
                in
                case previous blockPath (State.root editorState) of
                    Nothing ->
                        Err "There is no previous element to backspace"

                    Just ( path, node ) ->
                        case node of
                            Block bn ->
                                case childNodes bn of
                                    Leaf ->
                                        case replaceWithFragment path (BlockNodeFragment Array.empty) markedRoot of
                                            Err s ->
                                                Err s

                                            Ok newRoot ->
                                                Ok
                                                    (editorState
                                                        |> withRoot (clearSelectionAnnotations newRoot)
                                                        |> withSelection
                                                            (selectionFromAnnotations
                                                                newRoot
                                                                (anchorOffset selection)
                                                                (focusOffset selection)
                                                            )
                                                    )

                                    _ ->
                                        Err "The previous element is not a block leaf"

                            Inline _ ->
                                Err "The previous element is not a block node"


groupSameTypeInlineLeaf : Inline -> Inline -> Bool
groupSameTypeInlineLeaf a b =
    case a of
        InlineElement _ ->
            case b of
                InlineElement _ ->
                    True

                Text _ ->
                    False

        Text _ ->
            case b of
                Text _ ->
                    True

                InlineElement _ ->
                    False


textFromGroup : List Inline -> String
textFromGroup leaves =
    String.join "" <|
        List.map
            (\leaf ->
                case leaf of
                    Text t ->
                        Text.text t

                    _ ->
                        ""
            )
            leaves


lengthsFromGroup : List Inline -> List Int
lengthsFromGroup leaves =
    List.map
        (\il ->
            case il of
                Text tl ->
                    String.length (Text.text tl)

                InlineElement _ ->
                    0
        )
        leaves



-- Find the inline fragment that represents connected text nodes
-- get the text in that fragment
-- translate the offset for that text
-- find where to backspace


backspaceWord : Transform
backspaceWord editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                Err "I cannot remove a word of a range selection"

            else
                case findTextBlockNodeAncestor (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "I can only remove a word on a text leaf"

                    Just ( p, n ) ->
                        case childNodes n of
                            InlineChildren arr ->
                                let
                                    groupedLeaves =
                                        -- group text nodes together
                                        List.Extra.groupWhile
                                            groupSameTypeInlineLeaf
                                            (Array.toList (toInlineArray arr))
                                in
                                case List.Extra.last (anchorNode selection) of
                                    Nothing ->
                                        Err "Somehow the anchor node is the root node"

                                    Just lastIndex ->
                                        let
                                            ( relativeLastIndex, group ) =
                                                List.foldl
                                                    (\( first, rest ) ( i, g ) ->
                                                        if not <| List.isEmpty g then
                                                            ( i, g )

                                                        else if List.length rest + 1 > i then
                                                            ( i, first :: rest )

                                                        else
                                                            ( i - (List.length rest + 1), g )
                                                    )
                                                    ( lastIndex, [] )
                                                    groupedLeaves

                                            groupText =
                                                textFromGroup group

                                            offsetUpToNewIndex =
                                                List.sum <|
                                                    List.take
                                                        relativeLastIndex
                                                    <|
                                                        lengthsFromGroup group

                                            offset =
                                                offsetUpToNewIndex + anchorOffset selection

                                            stringFrom =
                                                String.left offset groupText
                                        in
                                        if String.isEmpty stringFrom then
                                            Err "Cannot remove word a word if the text fragment is empty"

                                        else
                                            let
                                                matches =
                                                    Regex.findAtMost 1 DeleteWord.backspaceWordRegex stringFrom

                                                matchOffset =
                                                    case List.head matches of
                                                        Nothing ->
                                                            0

                                                        Just match ->
                                                            match.index

                                                ( newGroupIndex, newOffset, _ ) =
                                                    List.foldl
                                                        (\l ( i, o, done ) ->
                                                            if done then
                                                                ( i, o, done )

                                                            else if l < o then
                                                                ( i + 1, o - l, False )

                                                            else
                                                                ( i, o, True )
                                                        )
                                                        ( 0, matchOffset, False )
                                                    <|
                                                        lengthsFromGroup group

                                                newIndex =
                                                    lastIndex - (relativeLastIndex - newGroupIndex)

                                                newSelection =
                                                    range
                                                        (p ++ [ newIndex ])
                                                        newOffset
                                                        (anchorNode selection)
                                                        (anchorOffset selection)

                                                newState =
                                                    editorState |> withSelection (Just newSelection)
                                            in
                                            removeRangeSelection newState

                            _ ->
                                Err "I expected an inline leaf array"


deleteText : Transform
deleteText editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                Err "I can only backspace a collapsed selection"

            else
                case nodeAt (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "I was given an invalid path to delete text"

                    Just node ->
                        case node of
                            Block _ ->
                                Err "I cannot delete text if the selection a block node"

                            Inline il ->
                                case il of
                                    InlineElement _ ->
                                        Err "I cannot delete text if the selection an inline leaf"

                                    Text tl ->
                                        let
                                            textLength =
                                                String.length (Text.text tl)
                                        in
                                        if anchorOffset selection < (textLength - 1) then
                                            Err "I use the default behavior when deleting text when the anchor offset is not at the end of a text node"

                                        else if anchorOffset selection == (textLength - 1) then
                                            case
                                                replace
                                                    (anchorNode selection)
                                                    (Inline
                                                        (Text
                                                            (tl |> Text.withText (String.dropRight 1 (Text.text tl)))
                                                        )
                                                    )
                                                    (State.root editorState)
                                            of
                                                Err s ->
                                                    Err s

                                                Ok newRoot ->
                                                    Ok (editorState |> withRoot newRoot)

                                        else
                                            case next (anchorNode selection) (State.root editorState) of
                                                Nothing ->
                                                    Err "I cannot do delete because there is no neighboring text node"

                                                Just ( nextPath, nextNode ) ->
                                                    case nextNode of
                                                        Block _ ->
                                                            Err "Cannot delete the text of a block node"

                                                        Inline nextInlineLeafWrapper ->
                                                            case nextInlineLeafWrapper of
                                                                Text _ ->
                                                                    let
                                                                        newSelection =
                                                                            singleNodeRange nextPath 0 1
                                                                    in
                                                                    removeRangeSelection
                                                                        (editorState
                                                                            |> withSelection (Just newSelection)
                                                                        )

                                                                InlineElement _ ->
                                                                    Err "Cannot backspace the text of an inline leaf"


deleteInlineElement : Transform
deleteInlineElement editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                Err "I can only delete an inline element if the selection is collapsed"

            else
                case nodeAt (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "I was given an invalid path to delete text"

                    Just node ->
                        case node of
                            Block _ ->
                                Err "I cannot delete text if the selection a block node"

                            Inline il ->
                                let
                                    length =
                                        case il of
                                            Text t ->
                                                String.length (Text.text t)

                                            InlineElement _ ->
                                                0
                                in
                                if length < anchorOffset selection then
                                    Err "I cannot delete an inline element if the cursor is not at the end of an inline node"

                                else
                                    let
                                        incrementedPath =
                                            increment (anchorNode selection)
                                    in
                                    case nodeAt incrementedPath (State.root editorState) of
                                        Nothing ->
                                            Err "There is no next inline leaf to delete"

                                        Just incrementedNode ->
                                            case incrementedNode of
                                                Inline nil ->
                                                    case nil of
                                                        InlineElement _ ->
                                                            case
                                                                replaceWithFragment
                                                                    incrementedPath
                                                                    (InlineLeafFragment Array.empty)
                                                                    (State.root editorState)
                                                            of
                                                                Err s ->
                                                                    Err s

                                                                Ok newRoot ->
                                                                    Ok (editorState |> withRoot newRoot)

                                                        Text _ ->
                                                            Err "There is no next inline leaf element, found a text leaf"

                                                Block _ ->
                                                    Err "There is no next inline leaf, found a block node"


deleteBlockNode : Transform
deleteBlockNode editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| selectionIsEndOfTextBlock selection (State.root editorState) then
                Err "Cannot delete a block element if we're not at the end of a text block"

            else
                case next (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "There is no next node to delete"

                    Just ( path, node ) ->
                        case node of
                            Block bn ->
                                case childNodes bn of
                                    Leaf ->
                                        case
                                            replaceWithFragment
                                                path
                                                (BlockNodeFragment Array.empty)
                                                (State.root editorState)
                                        of
                                            Err s ->
                                                Err s

                                            Ok newRoot ->
                                                Ok <| (editorState |> withRoot (clearSelectionAnnotations newRoot))

                                    _ ->
                                        Err "The next node is not a block leaf"

                            Inline _ ->
                                Err "The next node is not a block leaf, it's an inline leaf"


deleteWord : Transform
deleteWord editorState =
    case State.selection editorState of
        Nothing ->
            Err "Nothing is selected"

        Just selection ->
            if not <| isCollapsed selection then
                Err "I cannot remove a word of a range selection"

            else
                case findTextBlockNodeAncestor (anchorNode selection) (State.root editorState) of
                    Nothing ->
                        Err "I can only remove a word on a text leaf"

                    Just ( p, n ) ->
                        case childNodes n of
                            InlineChildren arr ->
                                let
                                    groupedLeaves =
                                        List.Extra.groupWhile
                                            groupSameTypeInlineLeaf
                                            (Array.toList (toInlineArray arr))
                                in
                                case List.Extra.last (anchorNode selection) of
                                    Nothing ->
                                        Err "Somehow the anchor node is the root node"

                                    Just lastIndex ->
                                        let
                                            ( relativeLastIndex, group ) =
                                                List.foldl
                                                    (\( first, rest ) ( i, g ) ->
                                                        if not <| List.isEmpty g then
                                                            ( i, g )

                                                        else if List.length rest + 1 > i then
                                                            ( i, first :: rest )

                                                        else
                                                            ( i - (List.length rest + 1), g )
                                                    )
                                                    ( lastIndex, [] )
                                                    groupedLeaves

                                            groupText =
                                                textFromGroup group

                                            offsetUpToNewIndex =
                                                List.sum <|
                                                    List.take
                                                        relativeLastIndex
                                                    <|
                                                        lengthsFromGroup group

                                            offset =
                                                offsetUpToNewIndex + anchorOffset selection

                                            stringTo =
                                                String.dropLeft offset groupText
                                        in
                                        if String.isEmpty stringTo then
                                            Err "Cannot remove word a word if the text fragment is empty"

                                        else
                                            let
                                                matches =
                                                    Regex.findAtMost 1 DeleteWord.deleteWordRegex stringTo

                                                matchOffset =
                                                    case List.head matches of
                                                        Nothing ->
                                                            0

                                                        Just match ->
                                                            match.index + String.length match.match

                                                ( newGroupIndex, newOffset, _ ) =
                                                    List.foldl
                                                        (\l ( i, o, done ) ->
                                                            if done then
                                                                ( i, o, done )

                                                            else if l < o then
                                                                ( i + 1, o - l, False )

                                                            else
                                                                ( i, o, True )
                                                        )
                                                        ( 0, offset + matchOffset, False )
                                                    <|
                                                        lengthsFromGroup group

                                                newIndex =
                                                    lastIndex - (relativeLastIndex - newGroupIndex)

                                                newSelection =
                                                    range
                                                        (p ++ [ newIndex ])
                                                        newOffset
                                                        (anchorNode selection)
                                                        (anchorOffset selection)

                                                newState =
                                                    editorState |> withSelection (Just newSelection)
                                            in
                                            removeRangeSelection newState

                            _ ->
                                Err "I expected an inline leaf array"