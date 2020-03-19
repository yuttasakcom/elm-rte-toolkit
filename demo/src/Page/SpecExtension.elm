module Page.SpecExtension exposing (..)

import Array
import Controls exposing (EditorMsg(..), Style(..))
import Editor
import ExtraMarks exposing (strikethrough, underline)
import Html exposing (Html, a, button, div, h1, p, text)
import Html.Attributes exposing (href, title)
import Html.Events exposing (onClick)
import Json.Decode as D
import Links exposing (rteToolkit)
import RichTextEditor.Commands as Commands
import RichTextEditor.Decorations exposing (addElementDecoration, selectableDecoration)
import RichTextEditor.Internal.Editor exposing (applyCommand, applyCommandNoForceSelection)
import RichTextEditor.Model.Annotation exposing (selectableAnnotation)
import RichTextEditor.Model.Attribute
    exposing
        ( Attribute(..)
        , findStringAttribute
        , replaceOrAddStringAttribute
        )
import RichTextEditor.Model.Command exposing (Transform, transformCommand)
import RichTextEditor.Model.Editor exposing (DecoderFunc, decorations, withDecorations)
import RichTextEditor.Model.HtmlNode exposing (HtmlNode(..))
import RichTextEditor.Model.Node exposing (BlockNode, ChildNodes(..), ElementParameters, Node(..), Path, attributesFromElementParameters, blockArray, blockNode, blockNodeWithElementParameters, elementParameters, elementParametersFromBlockNode, elementParametersWithAttributes, inlineLeafArray, nameFromElementParameters, textLeafWithText)
import RichTextEditor.Model.Spec exposing (ElementToHtml, HtmlToElement, HtmlToMark, MarkDefinition, MarkToHtml, NodeDefinition, Spec, blockLeafContentType, markDefinition, markDefinitions, nodeDefinition, nodeDefinitions, textBlockContentType, withMarkDefinitions, withNodeDefinitions)
import RichTextEditor.Model.State as State exposing (State, withRoot)
import RichTextEditor.Node as Node exposing (nodeAt)
import RichTextEditor.Spec exposing (defaultHtmlToMark)
import RichTextEditor.Specs as MarkdownSpec exposing (doc, paragraph)
import Session exposing (Session)
import Set


type alias Model =
    { session : Session
    , editor : Editor.Model
    , insertCaptionedImageModal : InsertCaptionedImageModal
    }


type alias InsertCaptionedImageModal =
    { visible : Bool
    , editorState : Maybe State
    , src : String
    , alt : String
    , caption : String
    }


type Msg
    = ShowUpdateCaptionedImageModel
    | UpdateCaptionedImageSrc String
    | UpdateCaptionedImageAlt String
    | UpdateCaption String
    | InsertCaptionedImage
    | EditorMsg Editor.EditorMsg
    | GotSession Session


handleShowInsertCaptionedImageModal : Model -> Model
handleShowInsertCaptionedImageModal model =
    let
        insertImageModal =
            model.insertCaptionedImageModal
    in
    { model
        | insertCaptionedImageModal =
            { insertImageModal
                | visible = True
                , editorState = Just (RichTextEditor.Model.Editor.state model.editor.editor)
            }
    }


handleUpdateCaptionedImageSrc : String -> Model -> Model
handleUpdateCaptionedImageSrc src model =
    let
        insertImageModal =
            model.insertCaptionedImageModal
    in
    { model | insertCaptionedImageModal = { insertImageModal | src = src } }


handleUpdateCaptionedImageAlt : String -> Model -> Model
handleUpdateCaptionedImageAlt alt model =
    let
        insertImageModal =
            model.insertCaptionedImageModal
    in
    { model | insertCaptionedImageModal = { insertImageModal | alt = alt } }


handleUpdateCaption : String -> Model -> Model
handleUpdateCaption caption model =
    let
        insertImageModal =
            model.insertCaptionedImageModal
    in
    { model | insertCaptionedImageModal = { insertImageModal | caption = caption } }


handleInsertCaptionedImage : Model -> Model
handleInsertCaptionedImage model =
    let
        insertImageModal =
            model.insertCaptionedImageModal

        editor =
            model.editor

        newEditor =
            case insertImageModal.editorState of
                Nothing ->
                    model.editor.editor

                Just _ ->
                    let
                        params =
                            elementParameters captionedImage
                                [ StringAttribute "src" insertImageModal.src
                                , StringAttribute "alt" insertImageModal.alt
                                , StringAttribute "caption" insertImageModal.caption
                                ]
                                (Set.singleton selectableAnnotation)

                        img =
                            blockNode params Leaf
                    in
                    Result.withDefault model.editor.editor <|
                        applyCommand
                            ( "insertImage"
                            , transformCommand <|
                                Commands.insertBlockNode img
                            )
                            model.editor.editor
    in
    { model
        | editor = { editor | editor = newEditor }
        , insertCaptionedImageModal =
            { insertImageModal
                | visible = False
                , editorState = Nothing
                , src = ""
                , alt = ""
                , caption = ""
            }
    }


renderInsertCaptionedImageModal : InsertCaptionedImageModal -> Html Msg
renderInsertCaptionedImageModal insertImageModal =
    Controls.modal insertImageModal.visible
        [ Html.h3 []
            [ Html.text "Insert captioned image" ]
        , Html.div
            []
            [ Html.input
                [ Html.Attributes.type_ "text"
                , Html.Attributes.name "src"
                , Html.Attributes.value insertImageModal.src
                , Html.Attributes.placeholder "Image URL (ex: https://via.placeholder.com/150.png)"
                , Html.Events.onInput UpdateCaptionedImageSrc
                ]
                []
            ]
        , Html.div
            []
            [ Html.input
                [ Html.Attributes.type_ "text"
                , Html.Attributes.name "alt"
                , Html.Attributes.value insertImageModal.alt
                , Html.Attributes.placeholder "Alt text"
                , Html.Events.onInput UpdateCaptionedImageAlt
                ]
                []
            ]
        , Html.div
            []
            [ Html.input
                [ Html.Attributes.type_ "text"
                , Html.Attributes.name "caption"
                , Html.Attributes.value insertImageModal.alt
                , Html.Attributes.placeholder "Caption"
                , Html.Events.onInput UpdateCaption
                ]
                []
            ]
        , Html.div
            []
            [ Html.button
                [ Html.Events.onClick InsertCaptionedImage ]
                [ Html.text "Insert" ]
            ]
        ]


view : Model -> { title : String, content : List (Html Msg) }
view model =
    { title = "Extending a specification"
    , content =
        [ h1 [] [ text "Extending a specification" ]
        , p []
            [ text """This example shows how you can extend a specification"""
            ]
        , captionedImageView model
        , Html.map EditorMsg (Editor.view model.editor)
        , p []
            [ text "You can see the code for this example in the "
            , a
                [ title "git repo"
                , href (rteToolkit ++ "/tree/master/demo/src/Page/SpecExtension.elm")
                ]
                [ text "git repo." ]
            ]
        ]
    }


captionedImageView : Model -> Html Msg
captionedImageView model =
    div []
        [ button [ onClick ShowUpdateCaptionedImageModel ] [ text "Insert captioned image" ]
        , renderInsertCaptionedImageModal model.insertCaptionedImageModal
        ]


customSpec : Spec
customSpec =
    MarkdownSpec.markdown
        |> withNodeDefinitions (nodeDefinitions MarkdownSpec.markdown ++ [ captionedImage ])
        |> withMarkDefinitions
            (markDefinitions MarkdownSpec.markdown
                ++ [ strikethrough, underline ]
            )


docInitNode : BlockNode
docInitNode =
    blockNode
        (elementParameters doc [] Set.empty)
        (blockArray (Array.fromList [ initialEditorNode, initialCaptionedImage, initialEditorNode ]))


initialEditorNode : BlockNode
initialEditorNode =
    blockNode
        (elementParameters paragraph [] Set.empty)
        (inlineLeafArray (Array.fromList [ textLeafWithText "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum." ]))


initialCaptionedImage : BlockNode
initialCaptionedImage =
    blockNode
        (elementParameters captionedImage
            [ StringAttribute "caption" "The elm logo!", StringAttribute "src" "/logo.svg" ]
            (Set.singleton selectableAnnotation)
        )
        Leaf


initialState : State
initialState =
    State.state docInitNode Nothing


init : Session -> ( Model, Cmd Msg )
init session =
    let
        editor =
            Editor.init initialState customSpec

        newDecorations =
            decorations editor.editor |> addElementDecoration "captioned_image" preventKeyDownPropagationDecoration

        newEditor =
            { editor
                | editor = editor.editor |> withDecorations newDecorations
                , styles = [ Bold, Italic, Strikethrough, Underline ]
            }
    in
    ( { session = session
      , editor = newEditor
      , insertCaptionedImageModal =
            { visible = False
            , editorState = Nothing
            , src = ""
            , alt = ""
            , caption = ""
            }
      }
    , Cmd.none
    )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        EditorMsg editorMsg ->
            case editorMsg of
                CaptionedImage path s ->
                    ( { model | editor = handleCaptionedImageText path s model.editor }, Cmd.none )

                _ ->
                    let
                        ( e, _ ) =
                            Editor.update editorMsg model.editor
                    in
                    ( { model | editor = e }, Cmd.none )

        ShowUpdateCaptionedImageModel ->
            ( handleShowInsertCaptionedImageModal model, Cmd.none )

        UpdateCaptionedImageSrc s ->
            ( handleUpdateCaptionedImageSrc s model, Cmd.none )

        UpdateCaptionedImageAlt s ->
            ( handleUpdateCaptionedImageAlt s model, Cmd.none )

        UpdateCaption s ->
            ( handleUpdateCaption s model, Cmd.none )

        InsertCaptionedImage ->
            ( handleInsertCaptionedImage model, Cmd.none )

        _ ->
            ( model, Cmd.none )


updateCaptionedImageText : Path -> String -> Transform
updateCaptionedImageText path value state =
    let
        r =
            State.root state
    in
    case nodeAt path (State.root state) of
        Nothing ->
            Err "There is no node at the given path"

        Just node ->
            case node of
                Inline _ ->
                    Err "I can only update captioned images, but I received an inline node"

                Block bn ->
                    let
                        ep =
                            elementParametersFromBlockNode bn

                        attributes =
                            attributesFromElementParameters ep

                        newAttributes =
                            replaceOrAddStringAttribute "caption" value attributes

                        newElementParameters =
                            ep |> elementParametersWithAttributes newAttributes

                        newBlockNode =
                            bn |> blockNodeWithElementParameters newElementParameters
                    in
                    if nameFromElementParameters ep /= "captioned_image" then
                        Err "I received a node that was not a captioned image"

                    else
                        case Node.replace path (Block newBlockNode) r of
                            Err s ->
                                Err s

                            Ok newRoot ->
                                Ok (state |> withRoot newRoot)


handleCaptionedImageText : Path -> String -> Editor.Model -> Editor.Model
handleCaptionedImageText path value model =
    { model
        | editor =
            Result.withDefault model.editor
                (applyCommandNoForceSelection
                    ( "updateCaptionedImageText"
                    , transformCommand <|
                        updateCaptionedImageText
                            path
                            value
                    )
                    model.editor
                )
    }


toSession : Model -> Session
toSession model =
    model.session


subscriptions : Model -> Sub Msg
subscriptions model =
    Session.changes GotSession (Session.navKey model.session)


captionedImage : NodeDefinition
captionedImage =
    nodeDefinition "captioned_image" "block" blockLeafContentType imageToHtmlNode htmlNodeToImage


imageToHtmlNode : ElementToHtml
imageToHtmlNode parameters _ =
    let
        caption =
            Maybe.withDefault
                ""
                (findStringAttribute "caption" (attributesFromElementParameters parameters))

        attributes =
            List.filterMap identity
                [ Just <| ( "src", Maybe.withDefault "" (findStringAttribute "src" (attributesFromElementParameters parameters)) )
                , Maybe.map (\x -> ( "alt", x )) (findStringAttribute "alt" (attributesFromElementParameters parameters))
                , Maybe.map (\x -> ( "title", x )) (findStringAttribute "title" (attributesFromElementParameters parameters))
                , Just ( "data-caption", caption )
                ]
    in
    ElementNode "figure"
        [ ( "contenteditable", "false" ) ]
        (Array.fromList
            [ ElementNode "img"
                attributes
                Array.empty
            , ElementNode "figcaption"
                []
                (Array.fromList
                    [ ElementNode "input"
                        [ ( "value", caption )
                        , ( "type", "text" )
                        , ( "class", "caption" )
                        , ( "placeholder", "Add a caption..." )
                        ]
                        Array.empty
                    ]
                )
            ]
        )


parseImageAttributes : HtmlNode -> Maybe (List Attribute)
parseImageAttributes node =
    case node of
        ElementNode name attributes children ->
            if name == "img" then
                Just <|
                    List.filterMap
                        (\( k, v ) ->
                            case k of
                                "src" ->
                                    Just <| StringAttribute "src" v

                                "alt" ->
                                    Just <| StringAttribute "alt" v

                                "title" ->
                                    Just <| StringAttribute "title" v

                                "data-caption" ->
                                    Just <| StringAttribute "caption" v

                                _ ->
                                    Nothing
                        )
                        attributes

            else
                Nothing

        _ ->
            Nothing


htmlNodeToImage : HtmlToElement
htmlNodeToImage def node =
    case node of
        ElementNode name _ children ->
            if name == "figure" then
                case Array.get 0 children of
                    Nothing ->
                        Nothing

                    Just img ->
                        case parseImageAttributes img of
                            Nothing ->
                                Nothing

                            Just attr ->
                                Just
                                    ( elementParameters
                                        def
                                        attr
                                        (Set.singleton selectableAnnotation)
                                    , Array.empty
                                    )

            else
                Nothing

        _ ->
            Nothing


preventKeyDownPropagationDecoration : DecoderFunc EditorMsg -> Path -> ElementParameters -> Path -> List (Html.Attribute EditorMsg)
preventKeyDownPropagationDecoration decoder editorNodePath elementParameters elementPath =
    if elementPath == [] then
        selectableDecoration decoder editorNodePath elementParameters elementPath

    else if elementPath == [ 1, 0 ] then
        [ Html.Events.stopPropagationOn "keydown" (D.succeed ( Noop, True ))
        , Html.Events.stopPropagationOn "beforeinput" (D.succeed ( Noop, True ))
        , Html.Events.onInput (CaptionedImage editorNodePath)
        ]

    else
        []