using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.KernelMemory;
using DotNetEnv;

public class Program
{
    public static async Task Main(string[] args)
    {
        Env.Load("../.env");
        var qdrantEndpoint = "http://qdrant.myia.io/qdrant";
        var apiKey = Environment.GetEnvironmentVariable("QDRANT_API_KEY");
        var openAiApiKey = Environment.GetEnvironmentVariable("OPENAI_API_KEY");

        if (string.IsNullOrEmpty(openAiApiKey))
        {
            Console.WriteLine("Warning: OPENAI_API_KEY environment variable not set.");
            Console.WriteLine("Using a dummy key for builder configuration, but this will fail if embeddings are generated.");
            openAiApiKey = "dummy-key";
        }

        Console.WriteLine($"Attempting to connect to Qdrant at: {qdrantEndpoint}");

        try
        {
            // Note: KernelMemory requires an embedding generator to be configured.
            // We use the OpenAI default here as a placeholder for the builder,
            // even though we are only listing collections and not generating embeddings.
            var memory = new KernelMemoryBuilder()
                .WithQdrantMemoryDb(qdrantEndpoint, apiKey)
                .WithOpenAIDefaults(openAiApiKey)
                .Build(new KernelMemoryBuilderBuildOptions
                {
                    AllowMixingVolatileAndPersistentData = true
                });

            Console.WriteLine("Successfully built Kernel Memory with Qdrant connector.");
            Console.WriteLine("Listing collections...");

            var collections = await memory.ListIndexesAsync();
            if (collections.Any())
            {
                Console.WriteLine("Available collections:");
                foreach (var collectionName in collections)
                {
                    Console.WriteLine($"- {collectionName}");
                }
            }
            else
            {
                Console.WriteLine("No collections found. This is expected if the database is new.");
            }

            Console.WriteLine("\nQdrant connection test successful!");
        }
        catch (Exception e)
        {
            Console.WriteLine("\nAn error occurred during the Qdrant connection test.");
            Console.WriteLine($"Error: {e.Message}");
            Console.WriteLine("\nTroubleshooting:");
            Console.WriteLine("1. Ensure the Qdrant container is running (`docker-compose up -d`).");
            Console.WriteLine("2. Check if the endpoint URL is correct and accessible from this machine.");
            Console.WriteLine("3. Verify that the API key is correct in both the script and the Qdrant configuration.");
            Console.WriteLine("4. If running this script from a different machine, check for firewall rules blocking the connection.");
        }
    }
}
