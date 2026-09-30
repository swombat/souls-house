If you have a look at the already downloaded RubyLLM documentation, you'll see that RubyLLM already supports agentic model with tools and so on.

For this "app kit" to be complete, I want there to be a proof of concept of an agentic conversation set up already.

Different conversations have different kinds of tools, so the system should enable the grouping of tools into groups, and a group of tools can be assigned to a chat all together.

This is somehwat above and beyond what RubyLLM supports out of the box, so will require some kind of new architecture to support it.

The system we design should support the following use case:

Create a web fetch tool that, if the LLM calls it with a URL, will use Curl to fetch the URL and pass the response back to the LLM. This should enable the LLM to summarise what it found at the URL.

A later version of this might do some pre-processing of the URL contents to reduce the amount of context load - but that will be done later, for now just fetch the URL and pass the contents to the LLM.

It should be possible to have the chat without the web fetch tool, then add it mid-conversation, and then remove it again.