module Rte.HtmlNode exposing (..)

import Array exposing (Array)
import Rte.Model exposing (ChildNodes(..), EditorBlockNode, EditorInlineLeaf(..), ElementParameters, HtmlNode(..), Mark, Spec, TextLeafContents)
import Rte.Spec exposing (findMarkDefinitionsFromSpec, findNodeDefinitionFromSpec)


{-| Renders marks to their HtmlNode representation.
-}
marksToHtmlNode : Spec -> List Mark -> HtmlNode -> HtmlNode
marksToHtmlNode spec marks node =
    let
        marksAndDefinitions =
            findMarkDefinitionsFromSpec marks spec
    in
    List.foldl
        (\( mark, markDefinition ) htmlNode -> markDefinition.toHtmlNode mark (Array.fromList [ htmlNode ]))
        node
        marksAndDefinitions


{-| Renders element parameters to their HtmlNode representation.
-}
elementToHtmlNode : Spec -> ElementParameters -> List Mark -> Array HtmlNode -> HtmlNode
elementToHtmlNode spec parameters marks children =
    let
        nodeDefinition =
            findNodeDefinitionFromSpec parameters.name spec

        renderedNode =
            nodeDefinition.toHtmlNode parameters children
    in
    marksToHtmlNode spec marks renderedNode


{-| Renders element block nodes to their HtmlNode representation.
-}
editorBlockNodeToHtmlNode : Spec -> EditorBlockNode -> HtmlNode
editorBlockNodeToHtmlNode spec node =
    elementToHtmlNode spec node.parameters [] (childNodesToHtmlNode spec node.childNodes)


{-| Renders child nodes to their HtmlNode representation.
-}
childNodesToHtmlNode : Spec -> ChildNodes -> Array HtmlNode
childNodesToHtmlNode spec childNodes =
    case childNodes of
        BlockArray blockArray ->
            Array.map (editorBlockNodeToHtmlNode spec) blockArray

        InlineLeafArray inlineLeafArray ->
            Array.map (editorInlineLeafToHtmlNode spec) inlineLeafArray.array

        Leaf ->
            Array.empty


{-| Renders text nodes to their HtmlNode representation.
-}
textToHtmlNode : Spec -> TextLeafContents -> HtmlNode
textToHtmlNode spec contents =
    marksToHtmlNode spec contents.marks (TextNode contents.text)


{-| Renders inline leaf nodes to their HtmlNode representation.
-}
editorInlineLeafToHtmlNode : Spec -> EditorInlineLeaf -> HtmlNode
editorInlineLeafToHtmlNode spec node =
    case node of
        TextLeaf contents ->
            textToHtmlNode spec contents

        InlineLeaf l ->
            elementToHtmlNode spec l.parameters l.marks Array.empty
